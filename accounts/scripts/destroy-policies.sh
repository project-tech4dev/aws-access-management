#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Best-effort teardown of one delegation's customer-managed policies in every
# target account. Invoked by Terraform as the destroy-time provisioner on
# terraform_data.delegated_iam_policies["<delegation>"] (and runnable by hand).
#
# Inputs (environment), in addition to those in lib.sh:
#   POLICY_NAMES  JSON array of policy names, in creation order. They are
#                 deleted in reverse order (delegation policy before boundaries).
#
# A policy that is still attached to an entity (an Identity Center role that
# still references it, or a role that uses it as a permissions boundary) is
# LEFT IN PLACE with a warning - that is not treated as a failure. Remove the
# reference from the permission set and re-provision it, then re-run to delete
# the leftovers. A genuine error (role not assumable, delete API failure) exits
# non-zero so Terraform retries.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${POLICY_NAMES:?}"
jq -e 'type == "array" and all(.[]; type == "string")' <<< "$POLICY_NAMES" >/dev/null \
  || { echo "POLICY_NAMES is not a JSON array of strings" >&2; exit 2; }

delete_policy() {
  # $1 = policy name. Returns 0 = deleted, absent or left in place (attached).
  local name="$1" arn attached v err
  arn="arn:aws:iam::${ACCOUNT_ID}:policy/${name}"
  if ! aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    echo "    $name absent"
    return 0
  fi

  # Attached to any group/user/role? Also catches use as a permissions
  # boundary, which likewise blocks delete-policy.
  attached="$(aws iam list-entities-for-policy --policy-arn "$arn" \
    --query '[PolicyGroups[].GroupName, PolicyUsers[].UserName, PolicyRoles[].RoleName][]' \
    --output text)"
  if [ -n "$attached" ]; then
    echo "    $name still attached (${attached//$'\t'/, }) - left in place" >&2
    return 0
  fi

  for v in $(aws iam list-policy-versions --policy-arn "$arn" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" >/dev/null
  done
  if ! err="$(aws iam delete-policy --policy-arn "$arn" 2>&1 >/dev/null)"; then
    case "$err" in
      *DeleteConflict*) echo "    $name attached elsewhere (delete conflict) - left in place" >&2; return 0 ;;
      *)                echo "    $name: $err" >&2; return 1 ;;
    esac
  fi
  echo "    deleted $name"
}

destroy_account() {
  local name
  while IFS= read -r name; do
    delete_policy "$name"
  done < <(jq -r 'reverse | .[]' <<< "$POLICY_NAMES")
}

for_each_account destroy destroy_account
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "Teardown incomplete for: ${FAILED[*]} - see warnings above." >&2
  exit 1
fi
echo "Teardown complete."
