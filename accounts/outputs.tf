output "target_account_ids" {
  description = "ACTIVE accounts assigned a delegation's permission set; they receive the policies."
  value       = local.target_account_ids
}

output "target_account_count" {
  description = "How many accounts the fan-out covers."
  value       = length(local.target_account_ids)
}

output "permission_set_arns" {
  description = "ARNs of the permission sets the delegation policies are attached to, by name."
  value       = { for name, ps in data.aws_ssoadmin_permission_set.this : name => ps.arn }
}

output "delegation_policies" {
  description = "Policy names each delegation creates in every account, in creation order."
  value       = { for k, policies in local.delegation_policies : k => [for p in policies : p.name] }
}

output "account_assignments" {
  description = "Assignments Terraform manages, as \"<permission set>/<GROUP|USER>:<name>/<account id>\"."
  value       = sort(keys(local.account_assignments))
}
