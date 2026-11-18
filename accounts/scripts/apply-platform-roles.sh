#!/usr/bin/env bash
# Create or update one platform role (ROLE_MANIFEST) in every target account.
# Run by terraform_data.platform_roles; see README, "How the fan-out works".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${ROLE_MANIFEST:?}"
jq -e '(.name | type) == "string" and (.trust_policy | type) == "string"
       and (.managed_policy_arns | type) == "array"' <<< "$ROLE_MANIFEST" >/dev/null \
  || { echo "ROLE_MANIFEST is not a valid role definition" >&2; exit 2; }

ROLE="$(jq -r .name <<< "$ROLE_MANIFEST")"
DESCRIPTION="$(jq -r .description <<< "$ROLE_MANIFEST")"

apply_account() {
  local trust="$WORK/${ACCOUNT_ID}-trust.json" arn
  with_account_id "$(jq -r .trust_policy <<< "$ROLE_MANIFEST")" > "$trust"

  if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$ROLE" \
      --policy-document "file://$trust" >/dev/null
    echo "    updated $ROLE"
  else
    aws iam create-role --role-name "$ROLE" \
      --description "$DESCRIPTION" \
      --assume-role-policy-document "file://$trust" \
      --tags Key=ManagedBy,Value=terraform-delegated-iam >/dev/null
    echo "    created $ROLE"
  fi

  while IFS= read -r arn; do
    aws iam attach-role-policy --role-name "$ROLE" \
      --policy-arn "$(with_account_id "$arn")" >/dev/null
  done < <(jq -r '.managed_policy_arns[]' <<< "$ROLE_MANIFEST")
}

for_each_account platform-role apply_account
report_and_exit
