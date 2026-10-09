#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run `terraform plan -out=tfplan` without printing the plan, and report only
# which resources change and how (logs of a public repository are public).
#
# Writes to $GITHUB_OUTPUT:  changes=<sorted "action address" list, ";"-joined>
# Writes to $GITHUB_STEP_SUMMARY: the same list as a table.
# Run from accounts/.
# ---------------------------------------------------------------------------
set -euo pipefail

if ! terraform plan -no-color -lock-timeout=5m -out=tfplan > plan.log 2>&1; then
  # Errors are needed to fix the run. Organization IDs are masked by then.
  grep -E -A20 '^(Error|│ Error)' plan.log || tail -n 40 plan.log
  exit 1
fi

changes="$(terraform show -json tfplan | jq -r '
  [ .resource_changes[]?
    | select(.change.actions != ["no-op"] and .change.actions != ["read"])
    | "\(.change.actions | join("+")) \(.address)" ]
  | sort | join(";")')"

{
  echo "### terraform plan"
  if [ -z "$changes" ]; then
    echo "No changes."
  else
    echo "| Action | Resource |"
    echo "|---|---|"
    tr ';' '\n' <<< "$changes" | sed -E 's/^([^ ]+) (.*)$/| \1 | `\2` |/'
  fi
  echo
  echo "Only addresses are shown; the logs of this repository are public."
  echo "Run \`terraform plan\` locally for the full diff."
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ -n "$changes" ]; then tr ';' '\n' <<< "$changes"; else echo "No changes."; fi
echo "changes=$changes" >> "${GITHUB_OUTPUT:-/dev/null}"
