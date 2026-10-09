#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Set up the GitHub repository and the AWS access its Terraform workflow uses.
# Every step is idempotent; re-run it to repair drift or to add new org
# members to the team.
#
#   bootstrap/github/setup.sh <config.env> [step ...]
#
# With no steps, runs all of them in this order:
#
#   preflight    check tools, logins and that AWS is the management account
#   repo         create the repository (if missing) and set merge options
#   teams        GH_TEAM = all current org members (Write);
#                GH_APPROVER_TEAM = only GH_APPROVER (Write, ruleset bypass)
#   actions      read-only GITHUB_TOKEN; approval for all fork PR workflows
#   code         write .github/CODEOWNERS; first push to an empty repo
#   aws          GitHub OIDC provider + plan/apply IAM roles in this account
#   environment  APPLY_ENVIRONMENT: GH_APPROVER must approve; main only
#   secrets      role ARNs, state bucket and tfvars (base64) as Actions secrets
#   rulesets     main: PR + passing "plan" check for everyone; code-owner
#                (GH_APPROVER) review, bypassable via PR by GH_APPROVER_TEAM
#
# Requirements: gh (logged in with scopes repo, workflow, admin:org; an org
# owner, or a member allowed to create repositories and teams), aws (management-account credentials), jq, git, terraform (only to
# read the state bucket name when STATE_BUCKET is unset).
# ---------------------------------------------------------------------------
set -euo pipefail

CONFIG="${1:?usage: $0 <config.env> [step ...]}"
shift
# shellcheck source=/dev/null
source "$CONFIG"

: "${GH_ORG:?}" "${GH_REPO:?}" "${GH_APPROVER:?}" "${GH_TEAM:?}" "${GH_APPROVER_TEAM:?}"
: "${GH_VISIBILITY:=public}" "${APPLY_ENVIRONMENT:=production}"
: "${AWS_REGION:=us-east-1}" "${STATE_KEY:=permissions/terraform.tfstate}"
: "${EXECUTION_ROLE_NAME:=OrganizationAccountAccessRole}"
: "${ROLE_NAME_PREFIX:=github-${GH_REPO}}" "${TFVARS_FILE:=accounts/terraform.tfvars}"
: "${COMMIT_MESSAGE:=Initial import}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="${GH_ORG}/${GH_REPO}"
OIDC_HOST="token.actions.githubusercontent.com"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

say() { printf '\n== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Team slugs are derived from names; keep names slug-shaped so they match.
for t in "$GH_TEAM" "$GH_APPROVER_TEAM"; do
  [[ "$t" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "team name '$t' must be lowercase letters, digits and hyphens"
done

state_bucket() {
  if [ -z "${STATE_BUCKET:-}" ]; then
    STATE_BUCKET="$(terraform -chdir="$ROOT/bootstrap/state-bucket" output -raw bucket_name 2>/dev/null)" \
      || die "set STATE_BUCKET (couldn't read bootstrap/state-bucket output)"
  fi
  printf '%s' "$STATE_BUCKET"
}

# ---------------------------------------------------------------------------
step_preflight() {
  say "preflight"
  local t
  for t in gh aws jq git; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
  gh auth status >/dev/null 2>&1 || die "run: gh auth login -h github.com -s admin:org,workflow"
  local scopes
  scopes="$(gh api -i user 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')"
  for t in repo workflow admin:org; do
    [[ ", $scopes," == *", $t,"* ]] || die "gh token lacks scope '$t': gh auth refresh -h github.com -s admin:org,workflow"
  done
  # Org owners can do everything here. A member works too if the org lets
  # members create repositories and teams (the creator becomes repo admin and
  # team maintainer); otherwise the repo or teams step fails with GitHub's error.
  if [ "$(gh api "user/memberships/orgs/$GH_ORG" --jq .role)" != admin ]; then
    echo "note: $(gh api user --jq .login) is a member, not an owner, of $GH_ORG"
  fi
  gh api "orgs/$GH_ORG/members/$GH_APPROVER" >/dev/null 2>&1 \
    || die "$GH_APPROVER is not a member of $GH_ORG"

  local caller mgmt
  caller="$(aws sts get-caller-identity --query Account --output text)"
  mgmt="$(aws organizations describe-organization --query Organization.MasterAccountId --output text)"
  [ "$caller" = "$mgmt" ] || die "AWS credentials must be for the management account"
  [ -f "$ROOT/$TFVARS_FILE" ] || die "missing $TFVARS_FILE"
  state_bucket >/dev/null
  echo "ok: gh user $(gh api user --jq .login), AWS management account, tools present"
}

# ---------------------------------------------------------------------------
step_repo() {
  say "repo $REPO"
  if ! gh repo view "$REPO" >/dev/null 2>&1; then
    gh repo create "$REPO" "--$GH_VISIBILITY" \
      --description "AWS IAM delegation, boundaries and guardrails (Terraform)"
  fi
  gh repo edit "$REPO" --delete-branch-on-merge --enable-wiki=false --enable-projects=false \
    --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false >/dev/null
  echo "ok"
}

# ---------------------------------------------------------------------------
ensure_team() {
  # $1 = name, $2 = description
  if ! gh api "orgs/$GH_ORG/teams/$1" >/dev/null 2>&1; then
    gh api -X POST "orgs/$GH_ORG/teams" -f name="$1" -f description="$2" -f privacy=closed >/dev/null
    echo "created team $1"
  fi
  gh api -X PUT "orgs/$GH_ORG/teams/$1/repos/$REPO" -f permission=push >/dev/null
}

step_teams() {
  say "teams"
  local user

  # Org owners already have admin access to every repository, so they are left
  # out. Existing members are skipped: re-adding one would reset their role
  # (and demote the creator, who is the team's maintainer, to member).
  ensure_team "$GH_TEAM" "Org members who can open PRs on $GH_REPO"
  while IFS= read -r user; do
    if gh api -X PUT "orgs/$GH_ORG/teams/$GH_TEAM/memberships/$user" -f role=member >/dev/null 2>&1; then
      echo "added $user to $GH_TEAM"
    else
      echo "WARNING: couldn't add $user to $GH_TEAM: $(gh api user --jq .login) is not its maintainer." >&2
      echo "  An org owner can add them, or make you maintainer:" >&2
      echo "  gh api -X PUT orgs/$GH_ORG/teams/$GH_TEAM/memberships/$(gh api user --jq .login) -f role=maintainer" >&2
    fi
  done < <(comm -23 \
      <(gh api --paginate "orgs/$GH_ORG/members?role=member" --jq '.[].login' | sort) \
      <(gh api --paginate "orgs/$GH_ORG/teams/$GH_TEAM/members" --jq '.[].login' | sort))
  echo "ok: $GH_TEAM has $(gh api --paginate "orgs/$GH_ORG/teams/$GH_TEAM/members" --jq '.[].login' | wc -l | tr -d ' ') members (org owners need no team)"

  # Creating a team adds the creator as a maintainer; this team must hold only
  # the approver, because it may bypass the review ruleset.
  ensure_team "$GH_APPROVER_TEAM" "May merge their own PRs on $GH_REPO (via PR only)"
  if ! gh api "orgs/$GH_ORG/teams/$GH_APPROVER_TEAM/memberships/$GH_APPROVER" >/dev/null 2>&1; then
    gh api -X PUT "orgs/$GH_ORG/teams/$GH_APPROVER_TEAM/memberships/$GH_APPROVER" -f role=maintainer >/dev/null
  fi
  while IFS= read -r user; do
    if [ "$user" != "$GH_APPROVER" ]; then
      gh api -X DELETE "orgs/$GH_ORG/teams/$GH_APPROVER_TEAM/memberships/$user" >/dev/null
      echo "removed $user from $GH_APPROVER_TEAM"
    fi
  done < <(gh api --paginate "orgs/$GH_ORG/teams/$GH_APPROVER_TEAM/members" --jq '.[].login')
  echo "ok: $GH_APPROVER_TEAM = $GH_APPROVER"
}

# ---------------------------------------------------------------------------
step_actions() {
  say "actions settings"
  # Workflows get a read-only token and can't approve PRs.
  gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  # Workflows from forks wait for a maintainer before they run.
  if [ "$GH_VISIBILITY" = public ]; then
    gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
      -f approval_policy=all_external_contributors
  fi
  echo "ok"
}

# ---------------------------------------------------------------------------
step_code() {
  say "code"
  mkdir -p "$ROOT/.github"
  printf '# Every change needs review by the approver (enforced by a ruleset).\n* @%s\n' "$GH_APPROVER" \
    > "$ROOT/.github/CODEOWNERS"

  if gh api "repos/$REPO/branches/main" >/dev/null 2>&1; then
    echo "ok: main exists; CODEOWNERS written locally - change it through a PR if it differs"
    return
  fi

  cd "$ROOT"
  [ -d .git ] || git init -q -b main
  if ! git remote get-url origin >/dev/null 2>&1; then
    if [ "$(gh config get git_protocol -h github.com)" = ssh ]; then
      git remote add origin "git@github.com:$REPO.git"
    else
      git remote add origin "https://github.com/$REPO.git"
    fi
  fi
  git add -A
  # Never publish deployment values or state.
  if git ls-files | grep -E '(^|/)(\.terraform/|[^/]*\.tfstate|backend\.hcl$|[^/]*\.tfvars$)'; then
    die "the files above must not be committed; fix .gitignore"
  fi
  git commit -q -m "$COMMIT_MESSAGE"
  git push -q -u origin main
  echo "ok: pushed main"
}

# ---------------------------------------------------------------------------
step_aws() {
  say "aws: OIDC provider and roles"
  local account org_id full_name bucket provider_arn
  account="$(aws sts get-caller-identity --query Account --output text)"
  org_id="$(aws organizations describe-organization --query Organization.Id --output text)"
  # GitHub's `sub` claim is case-sensitive; use the name exactly as GitHub reports it.
  full_name="$(gh api "repos/$REPO" --jq .full_name)"
  bucket="$(state_bucket)"
  provider_arn="arn:aws:iam::${account}:oidc-provider/${OIDC_HOST}"

  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" >/dev/null 2>&1; then
    if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" \
        --query ClientIDList --output text | grep -qw sts.amazonaws.com; then
      aws iam add-client-id-to-open-id-connect-provider \
        --open-id-connect-provider-arn "$provider_arn" --client-id sts.amazonaws.com
    fi
    echo "OIDC provider present"
  else
    # No thumbprint: IAM verifies GitHub's certificate against its own trusted CAs.
    aws iam create-open-id-connect-provider --url "https://$OIDC_HOST" \
      --client-id-list sts.amazonaws.com >/dev/null
    echo "created OIDC provider"
  fi

  trust() {
    # $@ = allowed `sub` values
    jq -n --arg p "$provider_arn" --arg h "$OIDC_HOST" --args '{
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Principal: { Federated: $p },
        Action: "sts:AssumeRoleWithWebIdentity",
        Condition: {
          StringEquals: { ($h + ":aud"): "sts.amazonaws.com", ($h + ":sub"): $ARGS.positional }
        }
      }]
    }' "$@"
  }

  # What `terraform plan` needs: Organizations / Identity Center reads, state
  # read, and the S3 lock file.
  local plan_policy apply_policy
  plan_policy="$(jq -n --arg b "arn:aws:s3:::$bucket" --arg k "$STATE_KEY" '{
    Version: "2012-10-17",
    Statement: [
      { Sid: "ReadOrgAndIdentityCenter", Effect: "Allow", Resource: "*",
        Action: ["organizations:Describe*", "organizations:List*", "sso:Describe*", "sso:Get*", "sso:List*"] },
      { Sid: "StateList", Effect: "Allow", Action: "s3:ListBucket", Resource: $b },
      { Sid: "StateRead", Effect: "Allow", Action: "s3:GetObject", Resource: "\($b)/\($k)" },
      { Sid: "StateLock", Effect: "Allow", Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        Resource: "\($b)/\($k).tflock" }
    ]
  }')"

  # What `terraform apply` needs on top of plan. The fan-out may assume the
  # execution role only in accounts of this organization.
  apply_policy="$(jq --arg b "arn:aws:s3:::$bucket" --arg k "$STATE_KEY" \
      --arg r "$EXECUTION_ROLE_NAME" --arg o "$org_id" '.Statement += [
    { Sid: "StateWrite", Effect: "Allow", Action: "s3:PutObject", Resource: "\($b)/\($k)" },
    { Sid: "ManageResourceControlPolicies", Effect: "Allow", Resource: "*",
      Action: ["organizations:CreatePolicy", "organizations:UpdatePolicy", "organizations:DeletePolicy",
               "organizations:AttachPolicy", "organizations:DetachPolicy",
               "organizations:TagResource", "organizations:UntagResource"] },
    { Sid: "AttachDelegationPoliciesToPermissionSets", Effect: "Allow", Resource: "*",
      Action: ["sso:AttachCustomerManagedPolicyReferenceToPermissionSet",
               "sso:DetachCustomerManagedPolicyReferenceFromPermissionSet",
               "sso:PutPermissionsBoundaryToPermissionSet",
               "sso:DeletePermissionsBoundaryFromPermissionSet",
               "sso:ProvisionPermissionSet"] },
    { Sid: "FanOutIntoMemberAccounts", Effect: "Allow", Action: "sts:AssumeRole",
      Resource: "arn:aws:iam::*:role/\($r)",
      Condition: { StringEquals: { "aws:ResourceOrgID": $o } } }
  ]' <<< "$plan_policy")"

  upsert_role() {
    # $1 = role name, $2 = description, $3 = trust policy, $4 = inline policy
    if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
      aws iam update-assume-role-policy --role-name "$1" --policy-document "$3"
      aws iam update-role --role-name "$1" --description "$2" --max-session-duration 3600
      echo "updated role $1"
    else
      aws iam create-role --role-name "$1" --description "$2" --max-session-duration 3600 \
        --assume-role-policy-document "$3" --tags Key=ManagedBy,Value=bootstrap-github-setup >/dev/null
      echo "created role $1"
    fi
    aws iam put-role-policy --role-name "$1" --policy-name terraform --policy-document "$4"
  }

  # Plan: pull requests, and main (the post-merge plan the approver reviews).
  upsert_role "${ROLE_NAME_PREFIX}-plan" "GitHub Actions: terraform plan for $full_name" \
    "$(trust "repo:${full_name}:pull_request" "repo:${full_name}:ref:refs/heads/main")" "$plan_policy"
  # Apply: only jobs in the protected environment.
  upsert_role "${ROLE_NAME_PREFIX}-apply" "GitHub Actions: terraform apply for $full_name" \
    "$(trust "repo:${full_name}:environment:${APPLY_ENVIRONMENT}")" "$apply_policy"
}

# ---------------------------------------------------------------------------
step_environment() {
  say "environment $APPLY_ENVIRONMENT"
  local approver_id
  approver_id="$(gh api "users/$GH_APPROVER" --jq .id)"
  # Admins can't skip the approval; the approver may approve runs they started.
  jq -n --argjson id "$approver_id" '{
    wait_timer: 0,
    prevent_self_review: false,
    can_admins_bypass: false,
    reviewers: [{ type: "User", id: $id }],
    deployment_branch_policy: { protected_branches: false, custom_branch_policies: true }
  }' | gh api -X PUT "repos/$REPO/environments/$APPLY_ENVIRONMENT" --input - >/dev/null

  if ! gh api "repos/$REPO/environments/$APPLY_ENVIRONMENT/deployment-branch-policies" \
      --jq '.branch_policies[].name' | grep -qx main; then
    gh api -X POST "repos/$REPO/environments/$APPLY_ENVIRONMENT/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null
  fi
  echo "ok: reviewer $GH_APPROVER, branch main only"
}

# ---------------------------------------------------------------------------
step_secrets() {
  say "secrets"
  local account
  account="$(aws sts get-caller-identity --query Account --output text)"
  # Secrets, not variables: GitHub masks secrets in logs, and logs of a public
  # repository are public.
  gh secret set AWS_PLAN_ROLE_ARN --repo "$REPO" \
    --body "arn:aws:iam::${account}:role/${ROLE_NAME_PREFIX}-plan"
  gh secret set TF_STATE_BUCKET --repo "$REPO" --body "$(state_bucket)"
  # Base64, so the secret is one line: GitHub masks multi-line secrets line by
  # line, which would also mask unrelated text such as a lone "}".
  base64 < "$ROOT/$TFVARS_FILE" | tr -d '\n' | gh secret set TFVARS_BASE64 --repo "$REPO"
  gh secret set AWS_APPLY_ROLE_ARN --repo "$REPO" --env "$APPLY_ENVIRONMENT" \
    --body "arn:aws:iam::${account}:role/${ROLE_NAME_PREFIX}-apply"
  gh variable set AWS_REGION --repo "$REPO" --body "$AWS_REGION"
  echo "ok"
}

# ---------------------------------------------------------------------------
upsert_ruleset() {
  # stdin = ruleset JSON (with .name)
  local body name id
  body="$(cat)"
  name="$(jq -r .name <<< "$body")"
  id="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$name\") | .id")"
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$REPO/rulesets/$id" --input - <<< "$body" >/dev/null
    echo "updated ruleset $name"
  else
    gh api -X POST "repos/$REPO/rulesets" --input - <<< "$body" >/dev/null
    echo "created ruleset $name"
  fi
}

step_rulesets() {
  say "rulesets"
  local team_id
  team_id="$(gh api "orgs/$GH_ORG/teams/$GH_APPROVER_TEAM" --jq .id)"

  # Everyone, no bypass: changes reach main only through a PR whose plan passed.
  jq -n '{
    name: "main: pull request and plan",
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    bypass_actors: [],
    rules: [
      { type: "deletion" },
      { type: "non_fast_forward" },
      { type: "pull_request", parameters: {
          required_approving_review_count: 0, dismiss_stale_reviews_on_push: true,
          require_code_owner_review: false, require_last_push_approval: false,
          required_review_thread_resolution: false } },
      { type: "required_status_checks", parameters: {
          strict_required_status_checks_policy: true,
          required_status_checks: [{ context: "plan" }] } }
    ]
  }' | upsert_ruleset

  # The approver's review. GitHub won't let them approve their own PR, so their
  # team may bypass this ruleset - only when merging a PR, never by pushing.
  jq -n --argjson team "$team_id" '{
    name: "main: approver review",
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    bypass_actors: [{ actor_id: $team, actor_type: "Team", bypass_mode: "pull_request" }],
    rules: [
      { type: "pull_request", parameters: {
          required_approving_review_count: 1, dismiss_stale_reviews_on_push: true,
          require_code_owner_review: true, require_last_push_approval: true,
          required_review_thread_resolution: false } }
    ]
  }' | upsert_ruleset
}

# ---------------------------------------------------------------------------
ALL_STEPS=(preflight repo teams actions code aws environment secrets rulesets)
STEPS=("$@")
[ "${#STEPS[@]}" -gt 0 ] || STEPS=("${ALL_STEPS[@]}")
for s in "${STEPS[@]}"; do
  declare -F "step_$s" >/dev/null || die "unknown step '$s' (steps: ${ALL_STEPS[*]})"
done
for s in "${STEPS[@]}"; do "step_$s"; done
say "done"
