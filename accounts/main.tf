# ---------------------------------------------------------------------------
# Discovery (read-only)
# ---------------------------------------------------------------------------

data "aws_ssoadmin_instances" "this" {
  provider = aws.idcaccount
}

locals {
  sso_instance_arn = tolist(data.aws_ssoadmin_instances.this.arns)[0]
}

# Every permission set named by any delegation.
data "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_set_names

  provider     = aws.idcaccount
  instance_arn = local.sso_instance_arn
  name         = each.key
}

# The org itself - used to discover the root id when var.ou_id is not set.
data "aws_organizations_organization" "current" {
  provider = aws.org
}

locals {
  # Fall back to the org root (r-xxxx) so an unset var.ou_id means "the whole org".
  ou_id = coalesce(var.ou_id, data.aws_organizations_organization.current.roots[0].id)
}

# All accounts beneath the OU, recursively (including nested OUs).
data "aws_organizations_organizational_unit_descendant_accounts" "targets" {
  provider  = aws.org
  parent_id = local.ou_id
}

locals {
  # Only ACTIVE accounts: a SUSPENDED (closed) account can't be assumed into and
  # the fan-out script treats an assume-role failure as fatal.
  target_account_ids = sort([
    for a in data.aws_organizations_organizational_unit_descendant_accounts.targets.accounts :
    a.id if a.status == "ACTIVE"
  ])
}

# ---------------------------------------------------------------------------
# Policy fan-out, one resource per delegation: a script assumes
# var.execution_role_name in each target account and upserts that delegation's
# policies (rendered in delegations.tf) there.
#
# Re-runs whenever the account set or the rendered policies change. Replacing a
# delegation first runs its destroy-time teardown, which leaves attached
# policies in place. Removing a delegation from var.delegations tears down only
# its policies. New accounts added to the OU are picked up on the next
# `terraform apply`.
# ---------------------------------------------------------------------------

resource "terraform_data" "delegated_iam_policies" {
  for_each = var.delegations

  triggers_replace = {
    account_ids    = join(",", local.target_account_ids)
    execution_role = var.execution_role_name
    policies       = sha256(jsonencode(local.delegation_policies[each.key]))
  }

  # Mirrored to `output` after apply so the destroy-time provisioner (which may
  # only reference `self`) can read these values.
  input = {
    account_ids    = join(",", local.target_account_ids)
    execution_role = var.execution_role_name
    policy_names   = jsonencode([for p in local.delegation_policies[each.key] : p.name])
    region         = var.region
  }

  lifecycle {
    precondition {
      condition     = alltrue([for p in local.delegation_policies[each.key] : length(p.document) <= 6144])
      error_message = "A rendered policy in delegation \"${each.key}\" exceeds the 6,144-character managed policy limit."
    }
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/apply-policies.sh"
    interpreter = ["/usr/bin/env", "bash"]
    environment = {
      ACCOUNT_IDS   = self.input.account_ids
      ROLE_NAME     = self.input.execution_role
      TARGET_REGION = self.input.region
      MANIFEST      = jsonencode(local.delegation_policies[each.key])
    }
  }

  # path.module, not a stored absolute path: the script must be found on
  # whichever machine runs the destroy (a CI runner or a laptop).
  provisioner "local-exec" {
    when        = destroy
    command     = "${path.module}/scripts/destroy-policies.sh"
    interpreter = ["/usr/bin/env", "bash"]
    environment = {
      ACCOUNT_IDS   = self.output.account_ids
      ROLE_NAME     = self.output.execution_role
      TARGET_REGION = self.output.region
      # State written before delegations existed has boundary_name and
      # delegation_name instead of policy_names.
      POLICY_NAMES = try(
        self.output.policy_names,
        jsonencode([self.output.boundary_name, self.output.delegation_name]),
      )
    }
  }
}

# ---------------------------------------------------------------------------
# Platform roles: the same fan-out pattern creates each role in var.platform_roles
# in every target account, WITHOUT a permissions boundary (e.g. EKS needs EC2,
# ELB and EKS access no role boundary allows). Delegation holders can't modify
# them (validation keeps them outside every prefix); a delegation's
# platform_roles only lets its holders pass them to named services.
#
# Deliberately no destroy-time provisioner: running workloads depend on these
# roles, and a replace (any trigger change) would delete them out from under
# those workloads. Roles orphaned by a rename, by removal from
# var.platform_roles or by `terraform destroy` must be deleted by hand once
# nothing uses them.
# ---------------------------------------------------------------------------

resource "terraform_data" "platform_roles" {
  for_each = var.platform_roles

  triggers_replace = {
    account_ids    = join(",", local.target_account_ids)
    execution_role = var.execution_role_name
    role           = sha256(jsonencode(local.platform_role_manifests[each.key]))
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/apply-platform-roles.sh"
    interpreter = ["/usr/bin/env", "bash"]
    environment = {
      ACCOUNT_IDS   = join(",", local.target_account_ids)
      ROLE_NAME     = var.execution_role_name
      TARGET_REGION = var.region
      ROLE_MANIFEST = jsonencode(local.platform_role_manifests[each.key])
    }
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC provider: created once per target account (users can't
# create OIDC providers). Users then create their own prefixed, boundary-capped
# CI roles that trust it.
#
# No destroy-time provisioner, for the same reason as the EKS roles: CI roles
# depend on it. Remove it by hand if it is ever retired.
# ---------------------------------------------------------------------------

resource "terraform_data" "github_oidc" {
  triggers_replace = {
    account_ids    = join(",", local.target_account_ids)
    execution_role = var.execution_role_name
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/apply-github-oidc.sh"
    interpreter = ["/usr/bin/env", "bash"]
    environment = {
      ACCOUNT_IDS   = join(",", local.target_account_ids)
      ROLE_NAME     = var.execution_role_name
      TARGET_REGION = var.region
    }
  }
}

# ---------------------------------------------------------------------------
# Guardrail for the provider above. Users write their CI roles' trust policies,
# and IAM can't inspect a trust policy's contents, so nothing stops a role that
# trusts every GitHub repo (no or wildcard `sub` condition). This resource
# control policy denies GitHub web-identity role assumption in every account
# under the OU unless the token comes from one of var.github_orgs.
#
# Prerequisite: RCPs enabled on the org root (one-time, management account):
#   aws organizations enable-policy-type --root-id r-xxxx \
#     --policy-type RESOURCE_CONTROL_POLICY
# ---------------------------------------------------------------------------

# Built with aws_iam_policy_document rather than jsonencode: Organizations stores
# a one-element list as a plain string, and jsonencode would then show a diff on
# every plan. The data source renders single values as strings too.
data "aws_iam_policy_document" "github_oidc_rcp" {
  statement {
    sid       = "DenyGitHubOidcOutsideTrustedOrgs"
    effect    = "Deny"
    actions   = ["sts:AssumeRoleWithWebIdentity"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    # Only GitHub tokens carry this key, so other web-identity federation is untouched.
    condition {
      test     = "Null"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["false"]
    }

    # Case-sensitive: must match the org name exactly as GitHub puts it in `sub`.
    condition {
      test     = "StringNotLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for org in var.github_orgs : "repo:${org}/*"]
    }
  }
}

resource "aws_organizations_policy" "github_oidc" {
  provider    = aws.org
  name        = "github-oidc-trusted-orgs"
  description = "Managed by Terraform (delegated-iam). GitHub OIDC role assumption only from trusted GitHub orgs."
  type        = "RESOURCE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.github_oidc_rcp.minified_json
}

resource "aws_organizations_policy_attachment" "github_oidc" {
  provider  = aws.org
  policy_id = aws_organizations_policy.github_oidc.id
  target_id = local.ou_id
}

# ---------------------------------------------------------------------------
# Data perimeter for role assumption. Users write their roles' trust policies,
# so nothing in IAM stops an `app-` role from trusting an account outside the
# org. This resource control policy denies sts:AssumeRole in every account
# under the OU unless the caller is in this org, is an AWS service, or is one
# of var.trusted_external_account_ids (third-party integrations).
#
# Web-identity and SAML federation are not affected (different actions).
# RCPs don't apply to the management account.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "sts_org_only_rcp" {
  statement {
    sid       = "DenyAssumeRoleFromOutsideOrg"
    effect    = "Deny"
    actions   = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "aws:PrincipalOrgID"
      values   = [data.aws_organizations_organization.current.id]
    }

    # Same operator as above, so the two keys are ANDed: deny only if the caller
    # is outside the org AND not a trusted external account.
    dynamic "condition" {
      for_each = length(var.trusted_external_account_ids) > 0 ? [1] : []
      content {
        test     = "StringNotEqualsIfExists"
        variable = "aws:PrincipalAccount"
        values   = var.trusted_external_account_ids
      }
    }

    # AWS services (EC2, ECS tasks, EKS, ...) assume roles as service principals.
    condition {
      test     = "BoolIfExists"
      variable = "aws:PrincipalIsAWSService"
      values   = ["false"]
    }
  }
}

resource "aws_organizations_policy" "sts_org_only" {
  provider    = aws.org
  name        = "sts-assumerole-org-only"
  description = "Managed by Terraform (delegated-iam). sts:AssumeRole only from principals in the org."
  type        = "RESOURCE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.sts_org_only_rcp.minified_json
}

resource "aws_organizations_policy_attachment" "sts_org_only" {
  provider  = aws.org
  policy_id = aws_organizations_policy.sts_org_only.id
  target_id = local.ou_id
}

# ---------------------------------------------------------------------------
# Attach each delegation policy to its permission sets, BY NAME.
# depends_on guarantees the policies exist in the target accounts first, so the
# permission set can resolve the reference when it provisions.
#
# The role boundary is NOT attached to the permission sets - it is the ceiling
# users put on the roles THEY create. A delegation that also has a
# permission-set-boundary.json.tftpl gets that policy attached as the
# permission sets' own permissions boundary, capping the users' sessions.
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_customer_managed_policy_attachment" "delegation" {
  for_each = local.permission_set_attachments

  provider           = aws.idcaccount
  instance_arn       = local.sso_instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.this[each.value.permission_set].arn

  customer_managed_policy_reference {
    name = local.delegation_policy_names[each.value.delegation]
    path = "/"
  }

  depends_on = [terraform_data.delegated_iam_policies]
}

resource "aws_ssoadmin_permissions_boundary_attachment" "delegation" {
  for_each = {
    for key, a in local.permission_set_attachments : key => a if local.has_permission_set_boundary[a.delegation]
  }

  provider           = aws.idcaccount
  instance_arn       = local.sso_instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.this[each.value.permission_set].arn

  permissions_boundary {
    customer_managed_policy_reference {
      name = local.permission_set_boundary_names[each.value.delegation]
      path = "/"
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.bounded_permission_sets) == length(distinct(local.bounded_permission_sets))
      error_message = "A permission set can have only one permissions boundary, but it is in more than one delegation with a permission-set-boundary.json.tftpl."
    }
  }

  depends_on = [terraform_data.delegated_iam_policies]
}

# ---------------------------------------------------------------------------
# Migration from the single-permission-set layout (before var.delegations).
# The old resources become the "poweruser" delegation. Remove these blocks once
# every deployment has applied them.
# ---------------------------------------------------------------------------

moved {
  from = terraform_data.delegated_iam_policies
  to   = terraform_data.delegated_iam_policies["poweruser"]
}

moved {
  from = aws_ssoadmin_customer_managed_policy_attachment.delegation
  to   = aws_ssoadmin_customer_managed_policy_attachment.delegation["poweruser/PowerUserAccess"]
}

# Replaced by terraform_data.platform_roles. It has no destroy-time provisioner,
# so dropping it from state deletes nothing in AWS.
removed {
  from = terraform_data.eks_roles

  lifecycle {
    destroy = false
  }
}
