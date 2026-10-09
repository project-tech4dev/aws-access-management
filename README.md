# AWS identity: delegated IAM for Identity Center permission sets

Terraform that lets users of IAM Identity Center permission sets (for example
`PowerUserAccess`) create their own IAM roles, safely, in **every account under
an OU** (or the whole organization). You define any number of
[delegations](#delegations), each with:

- a **role boundary** that caps every role its users create,
- a **delegation policy** on its permission sets that lets users create and pass
  roles only under the delegation's naming prefix and only with its boundary attached,
- optionally a **permission-set boundary** that caps the users' own sessions.

Shared by all delegations:

- **platform roles** (by default the EKS cluster and node roles) users can pass but not change,
- the **GitHub Actions OIDC provider**, guarded by a **resource control policy**
  that only lets your GitHub org(s) use it.

End-user instructions are in the [Developer guide](#developer-guide) at the end.

## Repository layout

| Directory | What it is | Applied |
|---|---|---|
| [`accounts/`](accounts/) | Delegation policies and boundaries, platform roles, GitHub OIDC provider, RCPs, fanned out to every account under the OU. **Start here.** | GitHub Actions (or locally) |
| [`bootstrap/state-bucket/`](bootstrap/state-bucket/main.tf) | S3 bucket for Terraform state, usable only by IAM roles inside the org. | Once, by hand (local state) |
| [`bootstrap/github/`](bootstrap/github/setup.sh) | Script that sets up the GitHub repository (teams, rulesets, environment, secrets) and the GitHub OIDC plan/apply roles in the management account. Reusable for other organizations. | By hand; idempotent, re-run to repair |
| [`.github/`](.github/workflows/terraform.yml) | Workflow: plan on pull request, approved apply on merge to `main`. | — |
| [`examples/`](examples/) | Trust and permissions policy templates for end users (see the [Developer guide](#developer-guide)), and an example `AdministratorAccess` delegation in `examples/delegations/admin/`. Not used by Terraform. | — |

`bootstrap/state-bucket/` is a separate Terraform configuration, applied once by
hand with its own local state. Apply it before running `bootstrap/github/setup.sh`,
which reads the bucket name from it.

All commands below run from the repository root unless they `cd` somewhere.

## Quickstart

### Prerequisites

- An AWS Organization with IAM Identity Center, and the existing permission sets
  your delegations name (for example `PowerUserAccess`) assigned to the accounts
  under the OU.
- `OrganizationAccountAccessRole` (or the role you set in `execution_role_name`)
  in every account under the OU. Organizations creates it only in accounts it
  created; add it by hand to invited accounts.
- Management-account credentials (or Organizations / Identity Center delegated
  admin plus a path to the execution role in each account). They must be an
  **IAM role session** (for example an Identity Center login), not an IAM user or
  the root user: the state bucket policy only allows roles inside the org.
- Terraform ≥ 1.10 (CI pins 1.10.5), `bash`, AWS CLI v2 and `jq`. The fan-out
  scripts shell out to the CLI and parse their manifests with `jq` (both are
  preinstalled on GitHub's `ubuntu-latest` runners).

### 1. One-time AWS setup

```bash
# State bucket. Apply with credentials for the account that should hold the
# state (e.g. an automation account, not the management account).
cd bootstrap/state-bucket
cp terraform.tfvars.example terraform.tfvars    # bucket_name, org_id
terraform init && terraform apply
cd ../..

# Enable resource control policies on the org root (management account).
aws organizations enable-policy-type \
  --root-id "$(aws organizations list-roots --query 'Roots[0].Id' --output text)" \
  --policy-type RESOURCE_CONTROL_POLICY
```

`bootstrap/state-bucket/` keeps its state in a local `terraform.tfstate`, which is
git-ignored. Keep it somewhere safe.

### 2. Configure

```bash
cd accounts
cp backend.hcl.example backend.hcl                # state bucket + region
cp terraform.tfvars.example terraform.tfvars      # ou_id, delegations, github_orgs
```

`delegations` and `github_orgs` are required. Every other value has a default in
[`variables.tf`](accounts/variables.tf). If you leave `ou_id` unset, the whole
organization is covered (the root id is looked up). Only `ACTIVE` accounts are
targeted, including those in nested OUs. Both files are git-ignored.

### 3a. Apply locally

```bash
cd accounts
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

State is stored at `permissions/terraform.tfstate` in the bucket, with native S3
locking (no DynamoDB table). After the first apply,
[test the GitHub guardrail](#github-actions-oidc).

### 3b. Apply from GitHub Actions

[`.github/workflows/terraform.yml`](.github/workflows/terraform.yml):

- **Pull request** (from a branch of the repository; fork PRs fail, because
  they get no AWS credentials): `terraform fmt -check`, `validate` and `plan`.
  The `plan` check must pass before merging.
- **Merge to `main`** (changes under `accounts/` or `.github/`, or a manual
  *Run workflow* on `main`): `plan-main` plans again. If anything changes, the
  `apply` job waits for the approver to approve the `production` environment,
  re-plans, stops if the changes differ from the approved plan, and applies.

Who can do what:

| | |
|---|---|
| Open PRs | Members of the `GH_TEAM` team (all org members), which has Write. |
| Approve PRs | Only `GH_APPROVER`, as the code owner (`.github/CODEOWNERS`). A new push dismisses the approval. |
| Merge own PRs without approval | Only `GH_APPROVER` (the `GH_APPROVER_TEAM` team may bypass the review ruleset, but only when merging a PR). |
| Push to `main` directly | Nobody. |
| Approve the apply | Only `GH_APPROVER`. Admins can't bypass it. |

**Public logs.** In a public repository anyone can read the Actions logs. The
workflow therefore takes every value from secrets (which GitHub masks), masks
account, organization, OU and Identity Center IDs, and shows only which
resources change and how, never the plan's contents. To review the full diff,
run `terraform plan` locally (step 3a) on the PR branch.

AWS access uses OIDC and two roles in the management account, created by the
setup script: a plan role (read-only; pull requests and `main`) and an apply role
(only jobs in the `production` environment; may assume the execution role only
in accounts of this organization).

**Set up** with an org owner's `gh` login and management-account AWS credentials:

```bash
gh auth login -h github.com -s admin:org,workflow
bootstrap/github/setup.sh bootstrap/github/project-tech4dev.env
```

For another organization, copy `project-tech4dev.env`, change the values and
pass the copy. Steps can be run one at a time, for example
`bootstrap/github/setup.sh <env> teams` to add new org members to the team. See
the header of [`setup.sh`](bootstrap/github/setup.sh) for the steps.

`TFVARS_BASE64` is the only copy of the deployment's values that CI sees. When
you change `accounts/terraform.tfvars`, update it:

```bash
bootstrap/github/setup.sh bootstrap/github/project-tech4dev.env secrets
```

## What it creates

| Resource | What it does |
|---|---|
| `terraform_data.delegated_iam_policies["<delegation>"]` | Runs `scripts/apply-policies.sh`, which assumes `execution_role_name` in each account and upserts the delegation's policies, rendered from `policies/delegations/<delegation>/`. |
| `aws_ssoadmin_customer_managed_policy_attachment.delegation["<delegation>/<permission set>"]` | Attaches the delegation policy to each of its permission sets, by name. |
| `aws_ssoadmin_permissions_boundary_attachment.delegation["<delegation>/<permission set>"]` | Only for delegations with a `permission-set-boundary.json.tftpl`: sets that policy as the permission sets' permissions boundary. |
| `terraform_data.platform_roles["<role>"]` | Runs `scripts/apply-platform-roles.sh`: creates the platform role in each account. |
| `terraform_data.github_oidc` | Runs `scripts/apply-github-oidc.sh`: creates the GitHub Actions OIDC provider in each account. |
| `aws_organizations_policy.github_oidc` + attachment | Resource control policy `github-oidc-trusted-orgs` on the OU: only `github_orgs` can use the GitHub OIDC provider. |
| `aws_organizations_policy.sts_org_only` + attachment | Resource control policy `sts-assumerole-org-only` on the OU: `sts:AssumeRole` only from principals in the org, AWS services, or `trusted_external_account_ids`. **List vendor accounts that assume roles here before the first apply**, or their integrations break. |

Outputs: `target_account_ids`, `target_account_count`, `permission_set_arns`,
`delegation_policies`.

The role boundary is never attached to the permission set. It is the ceiling
users put on the roles *they* create. To cap the users' own sessions, add a
separate `permission-set-boundary.json.tftpl` (see [Delegations](#delegations)).

### `terraform_data` and the fan-out scripts

`terraform_data` creates nothing in AWS. It stores its trigger values in state
and runs its `local-exec` script when created or replaced. The objects the
scripts create (policies, roles, OIDC provider) are **not** in Terraform state,
so:

- A script re-runs only when one of its `triggers_replace` values changes (the
  account list, the execution role, or the hash of the *rendered* policies or
  platform role). Editing a script does **not** re-run it. See
  [Changing a script](#changing-a-script).
- There is no drift detection. To repair a changed or deleted object, force a
  re-run: `terraform apply -replace=terraform_data.<name>`. The scripts are idempotent.
- New accounts in the OU are picked up on the **next apply**.
- If any account fails (the execution role can't be assumed, or any AWS call
  fails), the script still processes the others, then exits non-zero and the
  apply fails. Fix the cause and apply again.

**Why scripts instead of native resources:** a provider block can't use
`for_each`, and each `aws_iam_policy` needs a provider pinned to one account. So
Terraform can't create one resource per discovered account in a single apply.
The alternative is a service-managed CloudFormation StackSet on the OU, which
adds a second toolchain.

## Delegations

A delegation is one prefix plus one role boundary, granted to one or more
permission sets. Its key names the template directory:

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
    pass_to_services       = ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com", "pods.eks.amazonaws.com"]
    platform_roles         = { platform-eks-cluster = ["eks.amazonaws.com"], platform-eks-node = ["eks.amazonaws.com"] }
  }
}
```

To give a permission set more than one prefix and boundary, list it in more
than one delegation. Each prefix always maps to exactly one boundary. A
permission set can have only one permission-set boundary, so at most one of its
delegations may have `permission-set-boundary.json.tftpl`.

**Templates** are rendered with Terraform's `templatefile()` and checked as JSON
at plan time. They can use these variables:

| Variable | Value |
|---|---|
| `account_id` | The token `__ACCOUNT_ID__`, replaced by the scripts in each account. |
| `prefix`, `role_boundary_name` | This delegation's values. |
| `pass_to_services` | Services prefixed roles may be passed to. |
| `platform_roles` | Platform role name ⇒ services, for this delegation. |
| `all_platform_roles`, `all_prefixes` | Across every delegation / platform role. |
| `managed_policy_names` | Every policy this configuration creates. Protect them all, not just your own. |
| `execution_role_name` | The fan-out role, for templates that protect it. |

A template that needs loops or optional statements is easiest to write as
`${jsonencode({ ... })}`, as `poweruser/delegation.json.tftpl` does. A static
one can be plain JSON with `${account_id}` and `${prefix}`, as
`poweruser/role-boundary.json.tftpl` is.

**Allow or Deny.** The `poweruser` delegation is made of Allow statements, because
`PowerUserAccess` has no IAM permissions of its own. A permission set like
`AdministratorAccess` already allows `iam:*`, so Allows add nothing and its
delegation must be made of Denies. See `examples/delegations/admin/`, and copy it
to `accounts/policies/delegations/admin/` to use it. An admin inside an account
can usually find a way around Denies in identity policies, so use SCPs for
limits admins must not bypass.

**Validation** rejects configurations where one delegation could reach into
another's resources:

- a prefix that equals or starts another (`app` and `app-data`: `app-*` matches `app-data-*`),
- a managed policy name, platform role name or `execution_role_name` that starts with any `<prefix>-`,
- duplicate policy names across delegations,
- a delegation `platform_roles` entry that isn't in `var.platform_roles`,
- a rendered policy over the 6,144-character managed policy limit.

Removing a delegation from the map runs its teardown: its policies are deleted
in every account, except any still attached (see [Teardown](#teardown)).

## Files

Paths are relative to `accounts/` unless shown otherwise.

| File | Purpose |
|------|---------|
| `versions.tf` | Terraform ≥ 1.10, AWS provider ≥ 6.0, partial S3 backend (bucket/region from `backend.hcl`). |
| `providers.tf` | Default provider + optional `aws.org` / `aws.idcaccount` assume-role aliases (`org_role_arn`, `idcaccount_role_arn`). |
| `variables.tf` | Inputs, including `delegations` and `platform_roles` and their validations. |
| `delegations.tf` | Renders the delegation templates and platform roles into the manifests the scripts apply. |
| `main.tf` | Data sources, fan-outs, permission-set attachments, RCPs, migration blocks. |
| `outputs.tf` | Account list, account count, permission-set ARNs, policy names per delegation. |
| `.terraform.lock.hcl` | Provider lock file. Commit it. |
| `policies/delegations/<key>/*.json.tftpl` | Per-delegation templates (see [Delegations](#delegations)). |
| `policies/platform-roles/*.json` | Trust policies for the platform roles. |
| `scripts/lib.sh` | Shared account loop: assume the execution role, run a step, collect failures. |
| `scripts/apply-policies.sh` / `destroy-policies.sh` | Upsert / best-effort delete of one delegation's policies per account. |
| `scripts/apply-platform-roles.sh` | Upsert one platform role per account. Never deletes. |
| `scripts/apply-github-oidc.sh` | Create the GitHub OIDC provider per account. Never deletes. |
| `backend.hcl.example`, `terraform.tfvars.example` | Copy, fill in, keep out of git. |
| `examples/*.json` | Trust policy and deploy policy templates for end users (see the Developer guide). |
| `examples/delegations/admin/` | Example Deny-based delegation for `AdministratorAccess`. |
| `bootstrap/state-bucket/main.tf` | State bucket (one-time). |
| `bootstrap/github/setup.sh` + `*.env` | GitHub repository and CI AWS roles setup (idempotent). |
| `.github/workflows/terraform.yml` | Plan on PR, approved apply on merge. |
| `.github/actions/terraform-setup/` | Shared job setup: Terraform, AWS role, ID masking, tfvars, init. |
| `.github/scripts/plan-summary.sh` | Plan without printing it; report only resource addresses and actions. |
| `.github/CODEOWNERS` | Makes the approver the required reviewer. Written by the setup script. |

## Rolling out a policy change

Edit a template under `policies/delegations/<key>/` (or a value in that
delegation's entry), then apply (or merge). The hash of the rendered policies is
a trigger, so Terraform replaces only that delegation's
`terraform_data.delegated_iam_policies["<key>"]`:

1. `destroy-policies.sh` runs first. It skips any policy still attached to a role,
   so in steady state nothing is removed.
2. `apply-policies.sh` sets a new default policy version in every account. When
   a policy already has five versions, the oldest non-default one is deleted first.

The permission set references the delegation policy by name, so a new version
takes effect without re-provisioning.

Editing a platform role's trust policy or managed policies re-runs
`apply-platform-roles.sh` for that role, which resets its trust policy and
attaches any new managed policies. Nothing is deleted or detached.

## Changing a script

The scripts in `scripts/` are not triggers, so an edit to one changes nothing on
the next apply. To roll it out, force a re-run of the resource that calls it:

| Script | Re-run with |
|---|---|
| `apply-platform-roles.sh` | `terraform apply -replace='terraform_data.platform_roles["<role>"]'` |
| `apply-github-oidc.sh` | `terraform apply -replace=terraform_data.github_oidc` |
| `apply-policies.sh` | `terraform apply -replace='terraform_data.delegated_iam_policies["<key>"]'` |
| `lib.sh` | Re-run each resource whose script you need the change in. |

Replacing `delegated_iam_policies` runs `destroy-policies.sh` first, as in
[Rolling out a policy change](#rolling-out-a-policy-change).
`destroy-policies.sh` itself needs no re-run: Terraform runs the copy on disk
the next time the resource is replaced or destroyed.

In CI, `-replace` isn't available. Run it locally with the apply credentials, or
make the change in the same pull request as an edit that changes a trigger.

## Adding an account

Move or create the account under the OU, then apply. The new account must have
the execution role first (see [Prerequisites](#prerequisites)). Assign the
permission set to the account **after** the apply: provisioning fails in an
account where the delegation policies don't exist yet. If you assigned it first,
[re-provision](#permission-set-provisioning) after the apply.

The apply also re-runs the policy script in every existing account, because the
account list is a trigger. This is safe; the scripts are idempotent.

## Platform roles

Some services can't run on a role under a role boundary. EKS cluster and node
roles, for example, need EC2 networking, ELB and EKS API access that the
`poweruser` boundary withholds. `terraform_data.platform_roles` creates each role
in `var.platform_roles` in every account, **without** a boundary. The default is
the two EKS roles:

| Role (default name) | Trusted by | AWS managed policies |
|---|---|---|
| `platform-eks-cluster` | `eks.amazonaws.com` | `AmazonEKSClusterPolicy` |
| `platform-eks-node` | `ec2.amazonaws.com` | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` |

A delegation's `platform_roles` lets its users **pass** listed roles to listed
services (the `poweruser` delegation: both roles, to `eks.amazonaws.com`).
Validation keeps platform role names outside every prefix, so users can't
change them.

There is no destroy step: running workloads depend on these roles. After a
rename, removal from `var.platform_roles`, or `terraform destroy`, delete the old
roles by hand once nothing uses them.

## GitHub Actions OIDC

`terraform_data.github_oidc` creates the IAM OIDC provider for
`https://token.actions.githubusercontent.com` (audience `sts.amazonaws.com`) in
every account. If a provider already exists, it is kept and the audience is
added if missing. Users can't create OIDC providers. They create their own CI
roles, under the boundary, that trust it.

Users write those trust policies, and IAM can't check what a trust policy says.
So `aws_organizations_policy.github_oidc`, a **resource control policy** on the
OU, denies `sts:AssumeRoleWithWebIdentity` with a GitHub token unless its `sub`
is `repo:<org>/*` for an org in `github_orgs`. The match is case-sensitive. A role
that trusts every repo is then usable only from those orgs. Other web-identity
federation is not affected.

- **Test it after the first apply.** A workflow in a repo outside `github_orgs`
  must get `AccessDenied` from `AssumeRoleWithWebIdentity`. If it doesn't, the RCP
  isn't matching. Fix that before you rely on it.
- If a GitHub org customizes its OIDC `sub` claim format, the pattern won't match
  and the RCP blocks that org's workflows.
- RCPs don't apply to the management account, so they don't affect the CI roles
  from `bootstrap/github/setup.sh`.
- The provider has no destroy step (CI roles depend on it). Remove it by hand if
  it is retired.

## Permission set provisioning

Terraform provisions the permission set after it attaches the
customer-managed-policy reference. If the change doesn't reach the accounts (for
example, provisioning failed in an account that didn't have the policy yet),
provision once:

```bash
aws sso-admin provision-permission-set \
  --instance-arn <arn> --permission-set-arn <arn> \
  --target-type ALL_PROVISIONED_ACCOUNTS
```

## Teardown

`terraform destroy` detaches the delegation policies (and any permission-set
boundaries) from the permission sets, deletes the RCPs, then runs
`scripts/destroy-policies.sh` for each delegation to delete its policies in each
account, delegation policy first. A policy still attached to an entity is left
in place with a warning. Remove the reference, re-provision the permission set,
then re-run. A role boundary is deleted only once no roles use it. Platform roles
and the OIDC provider are never deleted automatically.

## Migrating from the single-permission-set layout

Earlier versions took `permission_set_name`, `prefix`, `boundary_policy_name`,
`delegation_policy_name`, `eks_cluster_role_name` and `eks_node_role_name`.
Replace them with a `poweruser` entry in `delegations` that uses the same names
(as in `terraform.tfvars.example`), and update the `TFVARS_BASE64` secret (`bootstrap/github/setup.sh <env> secrets`).

`moved` blocks in `main.tf` map the old resources to the `poweruser` delegation
and the `PowerUserAccess` permission set. If you used a different permission
set name, edit the second `moved` block to match before you apply. The old
`terraform_data.eks_roles` is dropped from state without deleting anything, and
`terraform_data.platform_roles` takes over the existing roles.

The first apply replaces the `poweruser` policy resource once, because the
trigger format changed. Its teardown leaves the delegation policy in place
(attached to the permission set). In an account where no `app-` roles exist
yet, it deletes the boundary, and the apply recreates it seconds later with the
same ARN.

The CI apply role created by `bootstrap/github/setup.sh` already has the
permissions for permission-set boundaries.

---

## Developer guide

This section is for users of the power-user permission set (the `poweruser`
delegation). Copy it to your
internal docs as needed.

The names below are the defaults from `accounts/variables.tf`: prefix `app-`,
boundary `PowerUserRoleBoundary`, EKS roles `platform-eks-cluster` and
`platform-eks-node`. If your deployment changes them, update this section to match.
The example files are in [`examples/`](examples/). The commands
below assume you run them from the repository root.

### Rules for all roles

1. The role name must start with `app-`.
2. Attach the permissions boundary `arn:aws:iam::<account-id>:policy/PowerUserRoleBoundary` when you create the role.
3. Policies and instance profiles that you create must also start with `app-`.

If you do not obey rules 1 and 2, AWS denies `CreateRole`. You cannot remove the
boundary from a role later.

Your roles can only use these services: S3, DynamoDB, SQS, SNS, CloudWatch,
CloudWatch Logs, SSM (including Session Manager), ECS and ECR. They also have
`secretsmanager:GetSecretValue`, `kms:Decrypt` and `kms:GenerateDataKey`, and
can be EventBridge target roles (`events:InvokeApiDestination` and
`events:PutEvents` in the account). AWS
denies all other actions, also if you attach a policy that allows them. Your
roles cannot do IAM actions, with one exception: they can pass `app-` roles to
ECS tasks (`iam:PassRole` to `ecs-tasks.amazonaws.com`). If you need a different
service, tell the platform team.

You yourself can pass `app-` roles to EC2, ECS tasks, EKS Pod Identity,
EventBridge rules and EventBridge Scheduler, and the two platform roles to EKS.

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
   The console's "create a new role" option fails: its role name doesn't start
   with `app-`.

Don't reuse an EC2 instance role: it trusts only `ec2.amazonaws.com`, so
EventBridge can't assume it. For EventBridge Scheduler targets (ECS tasks, SQS,
SNS), the role trusts `scheduler.amazonaws.com` instead. A schedule group has no
role; the role belongs to each schedule.

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

You cannot change the name of an IAM role. If your roles do not start with
`app-`, create new roles and update your task definitions.

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

To deploy to ECS from the workflow, do these steps:

1. Use the policy [`ecs-deploy-policy.json`](examples/ecs-deploy-policy.json) as the permissions policy. Name it `app-<repo>-deploy`.
2. Replace `<region>`, `<account-id>`, `<repository>` and `<service>`.
3. In `PassTaskAndExecutionRoles`, list only the task role and execution role of your service. The two roles must start with `app-`.

The workflow can then push images to ECR, register task definitions and update
the ECS service. It can pass `app-` roles only to ECS tasks. AWS denies all
other `iam:PassRole` requests.
