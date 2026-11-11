# ---------------------------------------------------------------------------
# Rendering: turns var.delegations and var.platform_roles into the manifests
# the fan-out scripts upsert. Templates are rendered here, once; the only value
# that differs per account is the account ID, which templates see as the token
# __ACCOUNT_ID__ and the scripts substitute.
#
# Template variables (available to every delegation template):
#   account_id            "__ACCOUNT_ID__" (replaced per account)
#   prefix                this delegation's prefix
#   role_boundary_name    this delegation's role boundary policy name
#   pass_to_services      services prefixed roles may be passed to
#   platform_roles        platform role name => services, for this delegation
#   all_platform_roles    every platform role name
#   all_prefixes          every delegation's prefix
#   managed_policy_names  every policy name this configuration manages
#   execution_role_name   var.execution_role_name
# ---------------------------------------------------------------------------

locals {
  delegation_template_dir = "${path.module}/policies/delegations"

  delegation_policy_names = {
    for k, d in var.delegations : k => coalesce(d.delegation_policy_name, "iam-delegation-${k}")
  }
  permission_set_boundary_names = {
    for k, d in var.delegations : k => coalesce(d.permission_set_boundary_name, "permission-set-boundary-${k}")
  }
  has_permission_set_boundary = {
    for k in keys(var.delegations) : k => fileexists("${local.delegation_template_dir}/${k}/permission-set-boundary.json.tftpl")
  }

  # The policies actually created.
  managed_policy_names = sort(flatten([
    for k, d in var.delegations : concat(
      [d.role_boundary_name, local.delegation_policy_names[k]],
      local.has_permission_set_boundary[k] ? [local.permission_set_boundary_names[k]] : [],
    )
  ]))

  template_vars = {
    for k, d in var.delegations : k => {
      account_id           = "__ACCOUNT_ID__"
      prefix               = d.prefix
      role_boundary_name   = d.role_boundary_name
      pass_to_services     = d.pass_to_services
      platform_roles       = d.platform_roles
      all_platform_roles   = sort(keys(var.platform_roles))
      all_prefixes         = sort([for x in values(var.delegations) : x.prefix])
      managed_policy_names = local.managed_policy_names
      execution_role_name  = var.execution_role_name
    }
  }

  # Per delegation, the policies to upsert in creation order: role boundary,
  # optional permission-set boundary, delegation policy. Teardown runs in
  # reverse. jsondecode/jsonencode rejects invalid JSON at plan time and minifies
  # (managed policies are limited to 6,144 characters).
  delegation_policies = {
    for k, d in var.delegations : k => concat(
      [{
        name     = d.role_boundary_name
        document = jsonencode(jsondecode(templatefile("${local.delegation_template_dir}/${k}/role-boundary.json.tftpl", local.template_vars[k])))
      }],
      local.has_permission_set_boundary[k] ? [{
        name     = local.permission_set_boundary_names[k]
        document = jsonencode(jsondecode(templatefile("${local.delegation_template_dir}/${k}/permission-set-boundary.json.tftpl", local.template_vars[k])))
      }] : [],
      [{
        name     = local.delegation_policy_names[k]
        document = jsonencode(jsondecode(templatefile("${local.delegation_template_dir}/${k}/delegation.json.tftpl", local.template_vars[k])))
      }],
    )
  }

  platform_role_manifests = {
    for name, r in var.platform_roles : name => {
      name                = name
      description         = r.description
      trust_policy        = jsonencode(jsondecode(file("${path.module}/policies/platform-roles/${r.trust_policy_file}")))
      managed_policy_arns = [for p in r.managed_policies : startswith(p, "arn:") ? p : "arn:aws:iam::aws:policy/${p}"]
    }
  }

  # Identity Center: one attachment per (delegation, permission set) pair.
  permission_set_names = toset(concat(
    flatten([for d in values(var.delegations) : d.permission_sets]),
    [for a in values(var.account_assignments) : a.permission_set],
  ))
  permission_set_attachments = merge([
    for k, d in var.delegations : {
      for ps in d.permission_sets : "${k}/${ps}" => { delegation = k, permission_set = ps }
    }
  ]...)

  # One assignment per (permission set, principal, account). Keyed by those
  # rather than the var.account_assignments key, so an assignment reached from
  # two entries (an OU and one of its accounts) is managed once, and renaming an
  # entry changes nothing.
  account_assignments = merge(flatten([
    for k, a in var.account_assignments : [
      for p in concat(
        [for g in a.groups : { type = "GROUP", name = g }],
        [for u in a.users : { type = "USER", name = u }],
        ) : {
        for acct in local.assignment_account_ids[k] : "${a.permission_set}/${p.type}:${p.name}/${acct}" => {
          permission_set = a.permission_set
          principal_type = p.type
          principal      = p.name
          account_id     = acct
        }
      }
    ]
  ])...)

  # A permission set can have only one permissions boundary.
  bounded_permission_sets = flatten([
    for k, d in var.delegations : d.permission_sets if local.has_permission_set_boundary[k]
  ])
}
