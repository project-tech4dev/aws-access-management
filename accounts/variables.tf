variable "region" {
  description = "Region where IAM Identity Center is enabled and where STS/CLI calls run (IAM policies themselves are global)."
  type        = string
  default     = "us-east-1"
}

variable "org_role_arn" {
  description = "Optional role ARN (management or Organizations delegated-admin account) that the aws.org provider assumes for Organizations reads. Leave null to use ambient credentials (e.g. running as the management account)."
  type        = string
  default     = null
  nullable    = true
}

variable "idcaccount_role_arn" {
  description = "Optional role ARN (Identity Center admin account) that the aws.idcaccount provider assumes for the permission-set lookup and attachment. Leave null to use ambient credentials."
  type        = string
  default     = null
  nullable    = true
}

variable "ou_id" {
  description = "OU to cover (e.g. ou-abcd-11111111), or a root id (r-xxxx). Leave null to cover the WHOLE org - the root id is discovered from the Organizations API. Applied to every ACTIVE account beneath it, including nested OUs."
  type        = string
  default     = null
  nullable    = true
}

variable "execution_role_name" {
  description = "Role the fan-out script assumes in each target account to create the policies. Must already exist in every account under the OU and be assumable by the credentials Terraform runs as."
  type        = string
  default     = "OrganizationAccountAccessRole"
}

variable "delegations" {
  description = <<-EOT
    Delegations, keyed by a short name that is also the template directory under
    policies/delegations/<key>/. Each one gives the users of its Identity Center
    permission sets the right to create IAM roles under `prefix`, capped by the
    role boundary rendered from role-boundary.json.tftpl. delegation.json.tftpl
    is attached to the permission sets. An optional
    permission-set-boundary.json.tftpl caps the permission sets' own sessions.

      permission_sets               Identity Center permission set names to attach to.
      prefix                        Name prefix for roles/policies/instance profiles ("<prefix>-*").
      role_boundary_name            Boundary every role created under the prefix must carry.
      delegation_policy_name        Default "iam-delegation-<key>".
      permission_set_boundary_name  Default "permission-set-boundary-<key>". Used only if the template exists.
      pass_to_services              Services prefixed roles may be passed to.
      platform_roles                Platform role name => services holders may pass it to.
  EOT
  type = map(object({
    permission_sets              = list(string)
    prefix                       = string
    role_boundary_name           = string
    delegation_policy_name       = optional(string)
    permission_set_boundary_name = optional(string)
    pass_to_services             = optional(list(string), [])
    platform_roles               = optional(map(list(string)), {})
  }))

  validation {
    condition     = length(var.delegations) > 0
    error_message = "Define at least one delegation."
  }

  validation {
    condition     = alltrue([for k in keys(var.delegations) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Delegation keys must be lowercase letters, digits and hyphens (they name template directories)."
  }

  validation {
    condition     = alltrue([for d in values(var.delegations) : length(d.permission_sets) > 0])
    error_message = "Every delegation must list at least one permission set."
  }

  validation {
    condition = alltrue([
      for d in values(var.delegations) :
      can(regex("^[A-Za-z0-9+=,.@_-]+$", d.prefix)) && !endswith(d.prefix, "-")
    ])
    error_message = "Prefixes must be valid IAM name characters and must not end in \"-\" (it is added)."
  }

  # With "app" and "app-data", "app-*" also matches "app-data-*": holders of the
  # first could edit the second's roles, or create roles under the weaker boundary.
  validation {
    condition = alltrue(flatten([
      for ka, a in var.delegations : [
        for kb, b in var.delegations : ka == kb || !startswith("${b.prefix}-", "${a.prefix}-")
      ]
    ]))
    error_message = "Delegation prefixes must be unique and none may be a prefix of another (\"app\" and \"app-data\" overlap)."
  }

  validation {
    condition = length(distinct(flatten([
      for k, d in var.delegations : [
        d.role_boundary_name,
        coalesce(d.delegation_policy_name, "iam-delegation-${k}"),
        coalesce(d.permission_set_boundary_name, "permission-set-boundary-${k}"),
      ]
      ]))) == length(flatten([
      for k, d in var.delegations : [
        d.role_boundary_name,
        coalesce(d.delegation_policy_name, "iam-delegation-${k}"),
        coalesce(d.permission_set_boundary_name, "permission-set-boundary-${k}"),
      ]
    ]))
    error_message = "Role boundary, delegation and permission-set boundary policy names must be unique across delegations."
  }

  # Otherwise one delegation's holders could edit a managed policy or role
  # through their own "<prefix>-*" grants.
  validation {
    condition = alltrue(flatten([
      for name in concat(flatten([
        for k, d in var.delegations : [
          d.role_boundary_name,
          coalesce(d.delegation_policy_name, "iam-delegation-${k}"),
          coalesce(d.permission_set_boundary_name, "permission-set-boundary-${k}"),
        ]
        ]), keys(var.platform_roles), [var.execution_role_name]) : [
        for d in values(var.delegations) : !startswith(name, "${d.prefix}-")
      ]
    ]))
    error_message = "Managed policy names, platform role names and execution_role_name must not start with any delegation's \"<prefix>-\"."
  }

  validation {
    condition = alltrue(flatten([
      for d in values(var.delegations) : [for r in keys(d.platform_roles) : contains(keys(var.platform_roles), r)]
    ]))
    error_message = "Every role in a delegation's platform_roles must be defined in var.platform_roles."
  }
}

variable "platform_roles" {
  description = <<-EOT
    Roles created in every account WITHOUT a permissions boundary, for services
    that need more than any role boundary allows (e.g. EKS). Delegation holders
    can't modify them; a delegation's platform_roles lets its holders pass them.

      trust_policy_file  Trust policy, relative to policies/platform-roles/.
      managed_policies   AWS managed policy names (e.g. "AmazonEKSClusterPolicy",
                         "service-role/...") or full ARNs. __ACCOUNT_ID__ is
                         replaced per account.
  EOT
  type = map(object({
    trust_policy_file = string
    managed_policies  = optional(list(string), [])
    description       = optional(string, "Managed by Terraform (delegated-iam). Platform role.")
  }))
  default = {
    platform-eks-cluster = {
      trust_policy_file = "eks-cluster-trust.json"
      managed_policies  = ["AmazonEKSClusterPolicy"]
      description       = "Managed by Terraform (delegated-iam). Platform EKS role."
    }
    platform-eks-node = {
      trust_policy_file = "eks-node-trust.json"
      managed_policies  = ["AmazonEKSWorkerNodePolicy", "AmazonEKS_CNI_Policy", "AmazonEC2ContainerRegistryReadOnly"]
      description       = "Managed by Terraform (delegated-iam). Platform EKS role."
    }
  }
}

variable "github_orgs" {
  description = "GitHub organizations whose Actions workflows may assume roles via the GitHub OIDC provider. Enforced by an RCP on the OU. Case-sensitive, exactly as the org name appears in GitHub."
  type        = list(string)

  validation {
    condition     = length(var.github_orgs) > 0
    error_message = "github_orgs must list at least one org, or the RCP would block all GitHub OIDC role assumption."
  }
}

variable "trusted_external_account_ids" {
  description = "AWS account IDs outside the org that may still assume roles in accounts under the OU (e.g. monitoring or security vendors). Everything else outside the org is denied by an RCP."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.trusted_external_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "trusted_external_account_ids must be 12-digit AWS account IDs."
  }
}
