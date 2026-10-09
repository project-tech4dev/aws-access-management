#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared helpers for the fan-out scripts. Source it; don't run it.
#
# Inputs (environment):
#   ACCOUNT_IDS    comma-separated account IDs under the OU
#   ROLE_NAME      role to assume in each account (e.g. OrganizationAccountAccessRole)
#   TARGET_REGION  region for STS/CLI calls (IAM itself is global)
#
# The caller's ambient AWS credentials must be able to sts:AssumeRole into
# ROLE_NAME in every listed account.
# ---------------------------------------------------------------------------
set -uo pipefail

: "${ACCOUNT_IDS:?}" "${ROLE_NAME:?}"
export AWS_DEFAULT_REGION="${TARGET_REGION:-us-east-1}"
export AWS_PAGER=""

for tool in aws jq; do
  command -v "$tool" >/dev/null || { echo "$tool not found on PATH" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Accounts the per-account function failed in (or that couldn't be assumed).
FAILED=()

# for_each_account <session-label> <function>
#
# Assumes ROLE_NAME in every account and runs <function> in a subshell with
# that account's credentials and ACCOUNT_ID exported. The subshell runs with
# `set -e`, so any failing command fails that account. A failure is recorded in
# FAILED and the loop moves on to the next account.
for_each_account() {
  local label="$1" fn="$2" account creds rc
  local -a accounts
  IFS=',' read -ra accounts <<< "$ACCOUNT_IDS"

  for account in "${accounts[@]}"; do
    account="${account//[[:space:]]/}"
    [ -z "$account" ] && continue
    echo "==> ${account}"

    if ! creds="$(aws sts assume-role \
          --role-arn "arn:aws:iam::${account}:role/${ROLE_NAME}" \
          --role-session-name "delegated-iam-${label}-$(date +%s)" \
          --duration-seconds 3600 \
          --query Credentials --output json 2>"$WORK/err")"; then
      echo "    assume-role failed: $(tr -d '\n' < "$WORK/err")" >&2
      FAILED+=("$account")
      continue
    fi

    # Not `( ... ) || ...`: bash ignores `set -e` inside a subshell whose exit
    # status is tested, which would hide failures. Check $? afterwards instead.
    (
      set -e
      export ACCOUNT_ID="$account"
      AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<< "$creds")"
      AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<< "$creds")"
      AWS_SESSION_TOKEN="$(jq -r .SessionToken <<< "$creds")"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      "$fn"
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "    failed (exit $rc)" >&2
      FAILED+=("$account")
    fi
  done
}

# report_and_exit: print the failed accounts (if any) and exit accordingly.
report_and_exit() {
  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "" >&2
    echo "FAILED for: ${FAILED[*]}" >&2
    echo "Ensure role '${ROLE_NAME}' exists in those accounts and is assumable by the" >&2
    echo "credentials Terraform runs as, then re-run 'terraform apply'." >&2
    exit 1
  fi
  echo "Done."
}

# with_account_id <string>: replace the __ACCOUNT_ID__ token with ACCOUNT_ID.
with_account_id() {
  printf '%s' "${1//__ACCOUNT_ID__/$ACCOUNT_ID}"
}
