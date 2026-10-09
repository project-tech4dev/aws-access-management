#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Upsert one delegation's customer-managed policies (role boundary, optional
# permission-set boundary, delegation policy) in every target account.
# Invoked by Terraform (terraform_data.delegated_iam_policies["<delegation>"]).
#
# Inputs (environment), in addition to those in lib.sh:
#   MANIFEST  JSON array of {"name": ..., "document": ...}, in creation order.
#             Documents are rendered by Terraform; the __ACCOUNT_ID__ token is
#             replaced here with each account's ID.
#
# Idempotent: an existing policy gets a new default version; it is never
# deleted here. Safe to re-run after fixing access to an unreachable account.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${MANIFEST:?}"
jq -e 'type == "array" and all(.[]; (.name | type) == "string" and (.document | type) == "string")' \
  <<< "$MANIFEST" >/dev/null || { echo "MANIFEST is not a valid policy list" >&2; exit 2; }

upsert_policy() {
  # $1 = policy name, $2 = path to the rendered policy document
  local name="$1" doc="$2" arn count oldest
  arn="arn:aws:iam::${ACCOUNT_ID}:policy/${name}"

  if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    # Stay under the 5-version limit before adding a new default version.
    count="$(aws iam list-policy-versions --policy-arn "$arn" \
      --query 'length(Versions)' --output text)"
    if [ "${count:-0}" -ge 5 ]; then
      oldest="$(aws iam list-policy-versions --policy-arn "$arn" \
        --query 'Versions[?IsDefaultVersion==`false`] | sort_by(@, &CreateDate)[0].VersionId' \
        --output text)"
      if [ -n "$oldest" ] && [ "$oldest" != "None" ]; then
        aws iam delete-policy-version --policy-arn "$arn" --version-id "$oldest" >/dev/null
      fi
    fi
    aws iam create-policy-version --policy-arn "$arn" \
      --policy-document "file://$doc" --set-as-default >/dev/null
    echo "    updated $name"
  else
    aws iam create-policy --policy-name "$name" \
      --description "Managed by Terraform (delegated-iam)." \
      --policy-document "file://$doc" >/dev/null
    echo "    created $name"
  fi
}

apply_account() {
  local i count name doc
  count="$(jq 'length' <<< "$MANIFEST")"
  for ((i = 0; i < count; i++)); do
    name="$(jq -r ".[$i].name" <<< "$MANIFEST")"
    doc="$WORK/${ACCOUNT_ID}-${i}.json"
    with_account_id "$(jq -r ".[$i].document" <<< "$MANIFEST")" > "$doc"
    upsert_policy "$name" "$doc"
  done
}

for_each_account policies apply_account
report_and_exit
