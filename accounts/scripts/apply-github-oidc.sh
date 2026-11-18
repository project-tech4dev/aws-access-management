#!/usr/bin/env bash
# Create the GitHub Actions OIDC provider in every target account.
# Run by terraform_data.github_oidc; see README, "How the fan-out works".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROVIDER_HOST="token.actions.githubusercontent.com"
AUDIENCE="sts.amazonaws.com"

upsert_provider() {
  local arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${PROVIDER_HOST}" audiences

  if audiences="$(aws iam get-open-id-connect-provider \
        --open-id-connect-provider-arn "$arn" \
        --query 'ClientIDList' --output text 2>/dev/null)"; then
    if [[ "$audiences" != *"$AUDIENCE"* ]]; then
      aws iam add-client-id-to-open-id-connect-provider \
        --open-id-connect-provider-arn "$arn" --client-id "$AUDIENCE" >/dev/null
      echo "    added audience $AUDIENCE to existing provider"
    else
      echo "    provider present"
    fi
  else
    # No thumbprint: IAM verifies GitHub's certificate against its own trusted CAs.
    aws iam create-open-id-connect-provider \
      --url "https://${PROVIDER_HOST}" \
      --client-id-list "$AUDIENCE" \
      --tags Key=ManagedBy,Value=terraform-delegated-iam >/dev/null
    echo "    created provider"
  fi
}

for_each_account oidc upsert_provider
report_and_exit
