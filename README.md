# AWS access management

This repository controls how people in our AWS Organization can create and use
IAM roles. It lets users of IAM Identity Center permission sets (for example
`PowerUserAccess`) create the IAM roles their workloads need, such as EC2
instance roles, ECS task roles and CI roles, without being able to give
those roles, or themselves, more access than the platform team allows.

It does this in every account under one OU (or the whole organization):

- **Delegations.** Each delegation gives one or more permission sets the right
  to create IAM roles, policies and instance profiles under a naming prefix
  (for example `app-`), but only with a **role boundary** attached. The
  boundary caps what those roles can ever do. A delegation can also cap the
  permission set's own sessions with a **permission-set boundary**.
- **Platform roles.** Roles that need more than any boundary allows (by default
  the EKS cluster and node roles) are created centrally. Users can pass them to
  the services that need them, but can't change them.
- **GitHub Actions OIDC provider** in every account, so teams can give their
  workflows AWS access without long-lived keys.
- **Guardrails** (resource control policies on the OU): only approved GitHub
  organizations can use the GitHub OIDC provider, and roles can't be assumed
  from AWS accounts outside the organization.

Changes are made by pull request. A GitHub Actions workflow plans every pull
request and, after merge and the approver's sign-off, applies the change.

**Who should read what:**

| You are | Read |
|---|---|
| Setting this up in a new organization | [One-time setup](#one-time-setup) |
| Changing policies, delegations or accounts | [Day-to-day operations](#day-to-day-operations) |
| Looking up what a component or setting does | [Components and configuration](#components-and-configuration) |
| A developer creating roles for your workloads | [Developer guide](#developer-guide) |

## Repository layout

| Path | What it is | How it's applied |
|---|---|---|
| [`accounts/`](accounts/) | The main Terraform configuration: delegations, platform roles, GitHub OIDC provider and guardrails, fanned out to every account under the OU. | GitHub Actions on merge (or locally) |
| [`bootstrap/state-bucket/`](bootstrap/state-bucket/main.tf) | S3 bucket for the `accounts/` Terraform state. | Once, by hand (local state) |
| [`bootstrap/github/`](bootstrap/github/setup.sh) | Script that sets up the GitHub repository and the AWS roles the workflow uses. Reusable for other organizations. | Once, by hand; re-run to repair or sync |
| [`.github/`](.github/workflows/terraform.yml) | The plan/apply workflow and its helpers. | — |
| [`examples/`](examples/) | Policy templates for developers, and an example `AdministratorAccess` delegation. Not used by Terraform. | — |

All commands below run from the repository root unless they `cd` somewhere.

---

## One-time setup

Do these steps once per organization, in order.

### Prerequisites

- An AWS Organization with IAM Identity Center, and the permission sets your
  delegations will extend (for example `PowerUserAccess`).
- `OrganizationAccountAccessRole` (or another role, set as `execution_role_name`)
  in every account under the OU, assumable from the management account.
  Organizations creates it only in accounts it created; add it by hand to
  invited accounts.
- Management-account AWS credentials.
- A GitHub organization, and a `gh` login that can create repositories and
  teams there (an org owner, or a member if the org allows members to).
- Terraform ≥ 1.10, `bash`, AWS CLI v2, `jq`, `git` and the GitHub CLI `gh`.

### 1. Create the state bucket

```bash
cd bootstrap/state-bucket
cp terraform.tfvars.example terraform.tfvars    # bucket_name, org_id
terraform init && terraform apply
cd ../..
```

Use credentials for the account that should hold the state. The bucket only
accepts IAM roles inside the organization. This configuration keeps its own
state in a local, git-ignored `terraform.tfstate`; keep that file somewhere safe.

### 2. Enable resource control policies

In the management account:

```bash
aws organizations enable-policy-type \
  --root-id "$(aws organizations list-roots --query 'Roots[0].Id' --output text)" \
  --policy-type RESOURCE_CONTROL_POLICY
```

### 3. Configure `accounts/`

```bash
cd accounts
cp backend.hcl.example backend.hcl                # state bucket + region
cp terraform.tfvars.example terraform.tfvars      # ou_id, delegations, github_orgs, ...
cd ..
```

`delegations` and `github_orgs` are required; see
[Inputs](#inputs-accountsvariablestf) for the rest. Both files are git-ignored.

Before the first apply, list in `trusted_external_account_ids` every AWS
account **outside** the organization that assumes roles in your accounts (for
example monitoring or security vendors). The
[`sts-assumerole-org-only`](#guardrails) guardrail blocks all others.

### 4. Set up the GitHub repository and CI access

[`bootstrap/github/setup.sh`](bootstrap/github/setup.sh) holds every `gh` and
AWS CLI command needed. It is idempotent. Copy its settings file for your
organization:

```bash
cp bootstrap/github/project-tech4dev.env bootstrap/github/<your-org>.env   # edit the values
gh auth login -h github.com -s admin:org,workflow
bootstrap/github/setup.sh bootstrap/github/<your-org>.env
```

It creates the repository, teams, Actions settings, `CODEOWNERS`, the AWS
OIDC provider and plan/apply roles, the `production` environment, the secrets
and the branch rulesets, and makes the first push to `main`. See
[GitHub repository and workflow](#github-repository-and-workflow) for what each
piece does.

If you're not an org owner, the script warns where an owner has to step in.
For example, adding members to the team after you've stopped being its
maintainer.

### 5. First apply

The first push to `main` starts the workflow. Review the plan summary of the
`plan-main` job, then approve the `production` environment to apply. (Or apply
locally: see [Running Terraform locally](#running-terraform-locally).)

Then:

1. **Assign the permission sets** to the accounts in Identity Center, if they
   aren't already. Assign them only after the apply: provisioning fails in an
   account where the delegation policy doesn't exist yet.
2. **Test the GitHub guardrail.** A workflow in a repository outside
   `github_orgs` must get `AccessDenied` from `AssumeRoleWithWebIdentity` in a
   member account. If it doesn't, the RCP isn't matching. Fix that before
   relying on it.

---

## Day-to-day operations

### Making a change

Every change goes through a pull request to `main`:

1. Create a branch **in this repository**, not a fork. Fork PRs get no AWS
   credentials, so their `plan` check fails.
2. Open a pull request. The `plan` job runs `terraform fmt -check`, `validate`
   and `plan`. It must pass.
3. The approver reviews and approves the pull request, then it is merged.
4. On `main`, the `plan-main` job plans again. If anything changes, the
   `apply` job waits for the approver to approve the `production` environment.
5. After approval, `apply` plans once more and stops if the list of changed
   resources differs from what was approved, then applies.

| Who | Can |
|---|---|
| Org members (team `aws-access-management`) | Push branches and open pull requests. |
| Org owners | Everything a repository admin can, including changing rulesets and the environment. |
| The approver (`GH_APPROVER`) | Approve pull requests (as code owner); approve applies; merge their own pull requests without an approval, but only through a pull request. |
| Anyone | Push to `main` directly: nobody can. Skip the `plan` check: nobody can. |

**The plan is not shown in the logs.** The repository is public, and so are its
Actions logs. The jobs show only which resources change and how (for example
`create terraform_data.platform_roles["platform-eks-node"]`). Account,
organization, OU and Identity Center IDs are masked. To review the full diff,
check out the branch and run `terraform plan` locally.

The apply's safety check compares the list of resources and actions, not their
contents. If `main` moves between approval and apply, re-run the workflow and
review again.

### Changing a delegation's policies

Edit a template under `accounts/policies/delegations/<key>/`, or that
delegation's entry in `terraform.tfvars`, and open a pull request. When applied,
only that delegation's `terraform_data.delegated_iam_policies["<key>"]` is
replaced:

1. `destroy-policies.sh` runs first. It leaves every policy that is still
   attached (the delegation policy on Identity Center roles, the boundary on
   roles that use it). In an account where a policy isn't attached to anything,
   it is deleted and recreated seconds later with the same ARN.
2. `apply-policies.sh` adds a new default version of each policy in every
   account. When a policy already has five versions, the oldest non-default one
   is deleted first.

Permission sets reference the delegation policy by name, so the new version
takes effect without re-provisioning.

### Changing `terraform.tfvars`

The workflow reads `accounts/terraform.tfvars` from the `TFVARS_BASE64` secret,
not from the repository. After changing the file locally, update the secret
and then open a pull request (any change under `accounts/` will do, or run the
workflow on `main` by hand):

```bash
bootstrap/github/setup.sh bootstrap/github/project-tech4dev.env secrets
```

### Adding or removing a delegation

- **Add:** create `accounts/policies/delegations/<key>/` with
  `delegation.json.tftpl` and `role-boundary.json.tftpl` (and optionally
  `permission-set-boundary.json.tftpl`), add the entry to `delegations` in
  `terraform.tfvars`, update the secret, open a pull request. See
  [Delegations](#delegations) for the templates and rules.
- **Remove:** remove the entry. The apply deletes its policies in every
  account, except those still attached (see [Teardown](#teardown)).

### Adding an account

1. Create or move the account under the OU. Make sure it has the execution role.
2. Run the workflow on `main` (**Actions → terraform (accounts) → Run
   workflow**), then approve the apply. A new account changes no file, so a
   merge alone doesn't pick it up.
3. Assign the permission sets to the account afterwards. If you assigned them
   first, [re-provision](#re-provisioning-a-permission-set) after the apply.

The apply re-runs every fan-out script in every account, because the account
list is a trigger. This is safe; the scripts are idempotent.

### Adding new org members to the team

```bash
bootstrap/github/setup.sh bootstrap/github/project-tech4dev.env teams
```

This needs a `gh` user who is an org owner or the team's maintainer. Org owners
don't need the team; they already have admin access.

### Changing a fan-out script

The scripts in `accounts/scripts/` are not triggers: editing one changes nothing
until its resource is replaced. Replace it locally (`-replace` isn't available
in CI), or make the change in the same pull request as an edit that changes a
trigger:

| Script | Re-run with |
|---|---|
| `apply-policies.sh` | `terraform apply -replace='terraform_data.delegated_iam_policies["<key>"]'` |
| `apply-platform-roles.sh` | `terraform apply -replace='terraform_data.platform_roles["<role>"]'` |
| `apply-github-oidc.sh` | `terraform apply -replace=terraform_data.github_oidc` |
| `lib.sh` | Each resource whose script needs the change. |

`destroy-policies.sh` needs no re-run: Terraform runs the copy on disk the next
time its resource is replaced or destroyed.

### Repairing drift

The objects the fan-out scripts create aren't in Terraform state, so Terraform
can't see if someone changes or deletes them. To repair them, replace the
resource as in the table above.

### Re-provisioning a permission set

Terraform provisions permission sets after attaching policies. If a change
doesn't reach an account (for example, provisioning failed because the policy
didn't exist there yet), provision once:

```bash
aws sso-admin provision-permission-set \
  --instance-arn <arn> --permission-set-arn <arn> \
  --target-type ALL_PROVISIONED_ACCOUNTS
```

### Running Terraform locally

Use an IAM **role** session in the management account, such as an Identity
Center admin login. The state bucket rejects IAM users.

```bash
cd accounts
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

### Teardown

Run locally: `terraform destroy`. It detaches the delegation policies and any
permission-set boundaries from the permission sets, deletes the RCPs, then
deletes each delegation's policies in every account, delegation policy first.
A policy still attached somewhere is left in place with a warning: remove the
reference, re-provision the permission set, then run again. A role boundary can
only be deleted once no roles use it. Platform roles and the GitHub OIDC
provider are never deleted automatically.

---

## Components and configuration

### `accounts/`: what it creates

| Resource | What it does |
|---|---|
| `terraform_data.delegated_iam_policies["<delegation>"]` | Runs `scripts/apply-policies.sh`: upserts the delegation's policies (role boundary, optional permission-set boundary, delegation policy) in every account. |
| `aws_ssoadmin_customer_managed_policy_attachment.delegation["<delegation>/<permission set>"]` | Attaches the delegation policy to each of its permission sets, by name. |
| `aws_ssoadmin_permissions_boundary_attachment.delegation["<delegation>/<permission set>"]` | Only for delegations with `permission-set-boundary.json.tftpl`: sets it as the permission sets' boundary. |
| `terraform_data.platform_roles["<role>"]` | Runs `scripts/apply-platform-roles.sh`: upserts the platform role in every account. |
| `terraform_data.github_oidc` | Runs `scripts/apply-github-oidc.sh`: creates the GitHub Actions OIDC provider in every account. |
| `aws_organizations_policy.github_oidc` + attachment | RCP `github-oidc-trusted-orgs` on the OU (see [Guardrails](#guardrails)). |
| `aws_organizations_policy.sts_org_only` + attachment | RCP `sts-assumerole-org-only` on the OU (see [Guardrails](#guardrails)). |

Outputs: `target_account_ids`, `target_account_count`, `permission_set_arns`,
`delegation_policies`.

### Inputs (`accounts/variables.tf`)

| Input | Default | Purpose |
|---|---|---|
| `delegations` | required | See [Delegations](#delegations). |
| `github_orgs` | required | GitHub organizations allowed to use the GitHub OIDC provider. Case-sensitive. |
| `ou_id` | whole org | OU (or root) whose `ACTIVE` accounts, including nested OUs, are covered. |
| `execution_role_name` | `OrganizationAccountAccessRole` | Role the fan-out scripts assume in each account. |
| `platform_roles` | the two EKS roles | See [Platform roles](#platform-roles). |
| `trusted_external_account_ids` | none | Accounts outside the org that may still assume roles here. |
| `region` | `us-east-1` | Identity Center region; region for STS and CLI calls. |
| `org_role_arn`, `idcaccount_role_arn` | none | Roles to assume for Organizations and Identity Center calls when Terraform doesn't run in the management account. |

### How the fan-out works

Terraform can't create one native resource per account discovered at plan time:
a provider block can't use `for_each`, and an `aws_iam_policy` needs a provider
pinned to one account. So `terraform_data` resources run scripts that assume
`execution_role_name` in each account and create the objects with the AWS CLI.
(The alternative, a CloudFormation StackSet, would add a second toolchain.)

- `terraform_data` creates nothing in AWS. It stores its triggers in state and
  runs its script when created or replaced.
- Triggers are the account list, the execution role, and a hash of the
  *rendered* policies or platform role. A new account, a template change or a
  tfvars change re-runs the script; editing the script itself does not.
- Templates are rendered by Terraform; the only per-account value is the
  account ID, which the scripts substitute for the token `__ACCOUNT_ID__`.
- If any account fails, the script still processes the others, then exits
  non-zero and the apply fails. Fix the cause and apply again.
- Scripts need `aws` and `jq` (preinstalled on GitHub's `ubuntu-latest` runners).

### Delegations

A delegation is one naming prefix plus one role boundary, granted to one or
more permission sets. Its key names its template directory:

```
accounts/policies/delegations/<key>/
  delegation.json.tftpl               required: attached to the permission sets
  role-boundary.json.tftpl            required: boundary on every role users create
  permission-set-boundary.json.tftpl  optional: boundary on the permission sets themselves
```

```hcl
delegations = {
  poweruser = {
    permission_sets        = ["PowerUserAccess"]
    prefix                 = "app"
    role_boundary_name     = "PowerUserRoleBoundary"
    delegation_policy_name = "poweruser-iam-delegation" # default "iam-delegation-<key>"
    pass_to_services       = ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com", "pods.eks.amazonaws.com",
                              "events.amazonaws.com", "scheduler.amazonaws.com"]
    platform_roles         = { platform-eks-cluster = ["eks.amazonaws.com"], platform-eks-node = ["eks.amazonaws.com"] }
  }
}
```

- `pass_to_services`: services users may pass their prefixed roles to.
- `platform_roles`: platform roles users may pass, and to which services.
- `permission_set_boundary_name`: default `permission-set-boundary-<key>`; used
  only if that template exists.

To give a permission set more than one prefix and boundary, list it in more
than one delegation. A permission set can have only one permission-set
boundary, so at most one of its delegations may have that template.

The role boundary is never attached to the permission set: it caps the roles
users *create*. Attaching it to the permission set would cancel the IAM
permissions the delegation policy grants.

**Templates** are rendered with Terraform's `templatefile()` and must be valid
JSON at plan time. Variables available to every template:

| Variable | Value |
|---|---|
| `account_id` | The token `__ACCOUNT_ID__`, replaced by the scripts in each account. |
| `prefix`, `role_boundary_name` | This delegation's values. |
| `pass_to_services`, `platform_roles` | This delegation's values. |
| `all_platform_roles`, `all_prefixes` | Across all platform roles / delegations. |
| `managed_policy_names` | Every policy this configuration creates. Protect them all, not just your own. |
| `execution_role_name` | The fan-out role, for templates that protect it. |

A template with loops or optional statements is easiest to write as
`${jsonencode({ ... })}`, like `poweruser/delegation.json.tftpl`. A static one
can be plain JSON with `${account_id}` and `${prefix}`, like
`poweruser/role-boundary.json.tftpl`.

**Allow or Deny.** The `poweruser` delegation is made of Allow statements,
because `PowerUserAccess` has no IAM permissions of its own. A permission set
like `AdministratorAccess` already allows `iam:*`, so Allows add nothing; its
delegation must be made of Denies. See
[`examples/delegations/admin/`](examples/delegations/admin/) and copy it to
`accounts/policies/delegations/admin/` to use it. An admin inside an account
can usually get around Denies in identity policies, so use SCPs for limits
admins must not bypass.

**Validation** rejects configurations where one delegation could reach into
another's resources:

- a prefix that equals or starts another (`app` and `app-data`: `app-*` matches `app-data-*`);
- a managed policy name, platform role name or `execution_role_name` that starts with any `<prefix>-`;
- duplicate policy names across delegations;
- a `platform_roles` entry that isn't in `var.platform_roles`;
- malformed keys or prefixes, or a delegation with no permission sets;
- a rendered policy over the 6,144-character managed policy limit (checked at plan).

### The `poweruser` delegation

| | |
|---|---|
| Permission set | `PowerUserAccess` |
| Users can create | Roles, policies and instance profiles named `app-*`; roles only with `PowerUserRoleBoundary` |
| Users can pass | `app-*` roles to EC2, ECS tasks, EKS Pod Identity, EventBridge and EventBridge Scheduler; the platform EKS roles to EKS |
| Roles they create can use | S3, DynamoDB, SQS, SNS, CloudWatch, CloudWatch Logs, SSM (including Session Manager), ECS, ECR; `secretsmanager:GetSecretValue`, `kms:Decrypt`, `kms:GenerateDataKey`; `events:InvokeApiDestination` and `events:PutEvents` in the same account; passing `app-*` roles to ECS tasks |
| Users can't | Remove a boundary, change the boundary or delegation policies, change roles outside `app-*`, create IAM users or OIDC providers |

### Platform roles

Some services can't run on a role under a role boundary. EKS cluster and node
roles, for example, need EC2 networking, ELB and EKS API access that the
`poweruser` boundary withholds. Each role in `var.platform_roles` is created in
every account **without** a boundary. The default:

| Role | Trusted by | AWS managed policies |
|---|---|---|
| `platform-eks-cluster` | `eks.amazonaws.com` | `AmazonEKSClusterPolicy` |
| `platform-eks-node` | `ec2.amazonaws.com` | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` |

Trust policies are in `accounts/policies/platform-roles/`. Validation keeps
platform role names outside every prefix, so users can't change them.
Re-running the script resets the trust policy and attaches any new managed
policies; it never detaches or deletes. After a rename, removal or
`terraform destroy`, delete old roles by hand once nothing uses them.

### GitHub OIDC provider

`terraform_data.github_oidc` creates the IAM OIDC provider for
`https://token.actions.githubusercontent.com` (audience `sts.amazonaws.com`) in
every account. An existing provider is kept, and the audience added if
missing. Users can't create OIDC providers; they create their own CI roles,
under the boundary, that trust this one. It is never deleted automatically.

### Guardrails

Two resource control policies (RCPs) on the OU. RCPs never apply to the
management account.

- **`github-oidc-trusted-orgs`.** Users write their CI roles' trust policies,
  and IAM can't check what a trust policy says. This RCP denies
  `sts:AssumeRoleWithWebIdentity` with a GitHub token unless its `sub` matches
  `repo:<org>/*` for an org in `github_orgs`, so even a role that trusts every
  repository only works from those orgs. Other web-identity federation is not
  affected. See [Known limitations](#known-limitations).
- **`sts-assumerole-org-only`.** Users also control their roles' trust towards
  other AWS accounts. This RCP denies `sts:AssumeRole` (and `TagSession`,
  `SetSourceIdentity`) unless the caller is in the organization, is an AWS
  service, or is in `trusted_external_account_ids`. Web-identity and SAML
  federation are not affected.

### `bootstrap/state-bucket/`

An S3 bucket for the `accounts/` state, with versioning, public access blocked,
TLS required, and access only for IAM roles inside the organization. State is
at `permissions/terraform.tfstate`, with native S3 locking (no DynamoDB table).

### GitHub repository and workflow

**Setup script.** `bootstrap/github/setup.sh <settings.env> [step ...]` runs all
steps, or the ones named. Each is idempotent:

| Step | Does |
|---|---|
| `preflight` | Checks tools, the `gh` login and scopes, and that the AWS credentials are for the management account. |
| `repo` | Creates the repository; squash merges only; deletes branches on merge. |
| `teams` | `GH_TEAM`: every org member except owners, with Write. `GH_APPROVER_TEAM`: only the approver, with Write. |
| `actions` | Read-only `GITHUB_TOKEN` that can't approve pull requests; fork workflows wait for approval. |
| `code` | Writes `.github/CODEOWNERS` (the approver); first push to an empty repository. |
| `aws` | GitHub OIDC provider and the plan/apply roles in the management account. |
| `environment` | `production`: the approver must approve; `main` only; admins can't bypass. |
| `secrets` | `AWS_PLAN_ROLE_ARN`, `TF_STATE_BUCKET`, `TFVARS_BASE64` (repository); `AWS_APPLY_ROLE_ARN` (environment); variable `AWS_REGION`. |
| `rulesets` | On `main`: pull request and passing `plan` check for everyone, no bypass; code-owner review, which `GH_APPROVER_TEAM` may bypass only when merging a pull request. |

Settings are in `bootstrap/github/<org>.env`: organization, repository,
visibility, approver, team names, environment, AWS region, state key, execution
role and role name prefix.

**AWS roles for the workflow** (management account):

- `<prefix>-plan`: read-only Organizations and Identity Center access, state
  read and lock. Trusted by pull requests and `main` of this repository.
- `<prefix>-apply`: plan's access, plus state write, RCP management,
  permission-set attachments, and assuming `execution_role_name` in accounts
  of this organization only. Trusted only by jobs in the `production`
  environment.

The trust policies use the repository's exact OIDC subject prefix, read from
GitHub. Newer repositories use immutable subjects
(`repo:<org>@<org-id>/<repo>@<repo-id>`), which a renamed or re-created
repository can't match.

**Workflow files:**

| File | Purpose |
|---|---|
| `.github/workflows/terraform.yml` | Jobs `plan` (pull requests), `plan-main` and `apply` (`main`). |
| `.github/actions/terraform-setup/` | Shared setup: Terraform, AWS role, masking of organization IDs, `terraform.tfvars` from the secret, `terraform init`. |
| `.github/scripts/plan-summary.sh` | Plans without printing the plan; reports only resource addresses and actions. |
| `.github/CODEOWNERS` | Makes the approver the required reviewer. |

### Files in `accounts/`

| File | Purpose |
|---|---|
| `versions.tf` | Terraform ≥ 1.10, AWS provider ≥ 6.0, partial S3 backend. |
| `providers.tf` | Default provider and the optional `aws.org` / `aws.idcaccount` aliases. |
| `variables.tf` | Inputs and their validations. |
| `delegations.tf` | Renders the templates and platform roles into the scripts' manifests. |
| `main.tf` | Discovery, fan-outs, permission-set attachments, RCPs, migration blocks. |
| `outputs.tf` | Outputs. |
| `policies/delegations/<key>/` | Delegation templates. |
| `policies/platform-roles/` | Platform role trust policies. |
| `scripts/lib.sh` | Shared account loop: assume the execution role, run a step, collect failures. |
| `scripts/apply-policies.sh`, `destroy-policies.sh` | Upsert / best-effort delete of one delegation's policies. |
| `scripts/apply-platform-roles.sh` | Upsert one platform role. |
| `scripts/apply-github-oidc.sh` | Create the GitHub OIDC provider. |
| `backend.hcl.example`, `terraform.tfvars.example` | Copy, fill in, keep out of git. |
| `.terraform.lock.hcl` | Provider lock file. Commit it. |

### Known limitations

- **GitHub immutable OIDC subjects.** Newer GitHub repositories issue tokens
  with `sub` = `repo:<org>@<org-id>/<repo>@<repo-id>:…`. The
  `github-oidc-trusted-orgs` RCP only matches `repo:<org>/…`, so workflows in
  such repositories are denied in member accounts. A GitHub org that customizes
  its `sub` claim format is blocked the same way.
- **The plan isn't visible in CI.** Review the full diff locally.
- **Org owners** can change the repository's rulesets and environment; GitHub
  offers no way to prevent that.
- **Team members can use the plan role** by editing the workflow in a pull
  request. It is read-only, but can read the Terraform state, Organizations and
  Identity Center configuration, and the tfvars secret.

### Migrating from the single-permission-set layout

Earlier versions took `permission_set_name`, `prefix`, `boundary_policy_name`,
`delegation_policy_name`, `eks_cluster_role_name` and `eks_node_role_name`.
Replace them with a `poweruser` entry in `delegations` that uses the same names
(as in `terraform.tfvars.example`), and update the `TFVARS_BASE64` secret.

`moved` blocks in `main.tf` map the old resources to the `poweruser` delegation
and the `PowerUserAccess` permission set; edit the second one if your
permission set had another name. The old `terraform_data.eks_roles` is dropped
from state without deleting anything, and `terraform_data.platform_roles` takes
over the existing roles.

The trigger format changed, so the first apply replaces the `poweruser` policy
resource once, with the teardown described in
[Changing a delegation's policies](#changing-a-delegations-policies). To avoid
it, run `terraform state rm terraform_data.delegated_iam_policies` before that
apply; the new resource is then only created.

---

## Developer guide

This section is for users of the `PowerUserAccess` permission set (the
`poweruser` delegation). Copy it to your internal docs as needed.

The names below are this deployment's values: prefix `app-`, boundary
`PowerUserRoleBoundary`, EKS roles `platform-eks-cluster` and
`platform-eks-node`. Example files are in [`examples/`](examples/); the
commands assume you run them from the repository root.

### Rules for all roles

1. The role name must start with `app-`.
2. Attach the permissions boundary `arn:aws:iam::<account-id>:policy/PowerUserRoleBoundary` when you create the role.
3. Policies and instance profiles that you create must also start with `app-`.

If you do not obey rules 1 and 2, AWS denies `CreateRole`. You cannot remove the
boundary from a role later. Console options that "create a new role" for you
fail, because their role names don't start with `app-`: create the role first,
then select it.

Your roles can only use these services: S3, DynamoDB, SQS, SNS, CloudWatch,
CloudWatch Logs, SSM (including Session Manager), ECS and ECR. They also have
`secretsmanager:GetSecretValue`, `kms:Decrypt` and `kms:GenerateDataKey`, and
can be EventBridge target roles (`events:InvokeApiDestination` and
`events:PutEvents` in the account). AWS denies all other actions, even if you
attach a policy that allows them. Your roles cannot do IAM actions, with one
exception: they can pass `app-` roles to ECS tasks. If you need another
service, ask the platform team.

You yourself can pass `app-` roles to EC2, ECS tasks, EKS Pod Identity,
EventBridge rules and EventBridge Scheduler, and the two platform roles to EKS.

### EC2 instance roles

1. Create the role with the trust policy [`ec2-trust-policy.json`](examples/ec2-trust-policy.json).
2. Attach a permissions policy.
3. Create an instance profile with the same name. Add the role to it.
4. Attach the instance profile to the instance.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BOUNDARY_ARN=arn:aws:iam::${ACCOUNT_ID}:policy/PowerUserRoleBoundary

aws iam create-role --role-name app-my-service-role \
  --assume-role-policy-document file://examples/ec2-trust-policy.json \
  --permissions-boundary "$BOUNDARY_ARN"

aws iam attach-role-policy --role-name app-my-service-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

aws iam create-instance-profile --instance-profile-name app-my-service-role
aws iam add-role-to-instance-profile \
  --instance-profile-name app-my-service-role --role-name app-my-service-role

aws ec2 associate-iam-instance-profile \
  --instance-id i-0123456789abcdef0 \
  --iam-instance-profile Name=app-my-service-role
```

### ECS task roles and execution roles

1. Create two roles for each service:
   - Execution role: `app-<service>-exec`. Example: `app-orders-exec`.
   - Task role: `app-<service>-task`. Example: `app-orders-task`.
2. Use the trust policy [`ecs-tasks-trust-policy.json`](examples/ecs-tasks-trust-policy.json) for the two roles. Replace `<account-id>`. Do not use the EC2 trust policy.
3. Attach the permissions boundary to the two roles.
4. Attach the AWS managed policy `service-role/AmazonECSTaskExecutionRolePolicy` to the execution role.
5. If the task definition gets secrets, give the execution role `secretsmanager:GetSecretValue` or `ssm:GetParameters`. Also give it `kms:Decrypt`. Use a policy that starts with `app-`.
6. Attach a policy to the task role. Give it only the permissions that your application needs.
7. In the task definition, set `executionRoleArn` and `taskRoleArn` to the two new roles.

You cannot rename an IAM role. If your roles do not start with `app-`, create
new roles and update your task definitions.

You can register task definitions with your PowerUserAccess session or from a
CD workflow. For a CD workflow, see [GitHub Actions](#github-actions).

### EKS

1. Do not create an EKS cluster role or node role. AWS denies the console option "create recommended role".
2. Create the cluster. For **Cluster IAM role**, select `platform-eks-cluster`.
3. Create the managed node group. For **Node IAM role**, select `platform-eks-node`.
4. If your pods need AWS access, use EKS Pod Identity:
   1. Install the `eks-pod-identity-agent` add-on on the cluster.
   2. Create a role that starts with `app-`. Attach the permissions boundary.
   3. Use the trust policy [`eks-pod-identity-trust-policy.json`](examples/eks-pod-identity-trust-policy.json).
   4. Run `aws eks create-pod-identity-association` to link the role to your Kubernetes service account.

You can use the two platform roles. You cannot change them.

Do not use IRSA. IRSA needs an IAM OIDC provider, and you cannot create one.

### Scheduled jobs (EventBridge)

To call an HTTP endpoint on a schedule (for example a cron endpoint):

1. Create an EventBridge **connection** (the endpoint's auth) and an **API
   destination** for the endpoint.
2. Create a role `app-<service>-eventbridge` with the permissions boundary and
   this trust policy (replace `<account-id>`):
   ```json
   { "Version": "2012-10-17", "Statement": [{ "Effect": "Allow",
     "Principal": { "Service": "events.amazonaws.com" }, "Action": "sts:AssumeRole",
     "Condition": { "StringEquals": { "aws:SourceAccount": "<account-id>" } } }] }
   ```
   Give it a policy (name starting `app-`) that allows `events:InvokeApiDestination`
   on the API destination's ARN.
3. Create a rule with a schedule (`rate(...)` or `cron(...)`), target the API
   destination, and select the role from step 2 under **Use existing role**.

Don't reuse an EC2 instance role: it trusts only `ec2.amazonaws.com`, so
EventBridge can't assume it. For EventBridge Scheduler targets (ECS tasks, SQS,
SNS), the role trusts `scheduler.amazonaws.com` instead. A schedule group has
no role; the role belongs to each schedule.

### GitHub Actions

Each account has the GitHub OIDC provider. Do not create it. Only workflows in
the GitHub organizations that the platform team approved can use it. AWS denies
workflows from other organizations.

1. Create a role for your workflow. Example: `app-<repo>-ci`. Attach the permissions boundary.
2. Use the trust policy [`github-actions-trust-policy.json`](examples/github-actions-trust-policy.json). Replace `<account-id>`, `<github-org>` and `<repo>`.
3. Set `sub` to one repository and one branch or environment. Do not use a wildcard.
4. Attach a permissions policy to the role. The policy name must start with `app-`.
5. In the workflow file, add this permission:

   ```yaml
   permissions:
     id-token: write
     contents: read
   ```

6. In the workflow, use the `aws-actions/configure-aws-credentials` action. Set `role-to-assume` to the ARN of your role. Set `aws-region` to your region.

**Check your repository's subject format first.** Newer repositories use
immutable subjects, `repo:<org>@<org-id>/<repo>@<repo-id>:…`, instead of
`repo:<org>/<repo>:…`. A repository admin can see which one yours uses:

```bash
gh api repos/<github-org>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
```

Use that prefix in `sub`. Immutable subjects are currently blocked by the
GitHub guardrail (see [Known limitations](#known-limitations)); ask the
platform team if your repository uses them.

To deploy to ECS from the workflow:

1. Use the policy [`ecs-deploy-policy.json`](examples/ecs-deploy-policy.json) as the permissions policy. Name it `app-<repo>-deploy`.
2. Replace `<region>`, `<account-id>`, `<repository>` and `<service>`.
3. In `PassTaskAndExecutionRoles`, list only the task role and execution role of your service. The two roles must start with `app-`.

The workflow can then push images to ECR, register task definitions and update
the ECS service. It can pass `app-` roles only to ECS tasks. AWS denies all
other `iam:PassRole` requests.
