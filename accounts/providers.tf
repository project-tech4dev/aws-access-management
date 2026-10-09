# Run Terraform with credentials that can:
#   1. read AWS Organizations and IAM Identity Center (management or delegated-admin), and
#   2. sts:AssumeRole into var.execution_role_name (default OrganizationAccountAccessRole)
#      in every account under the OU - the fan-out script uses these AMBIENT credentials,
#      it does not inherit the provider assume_role blocks below.
#
# The simplest setup that satisfies both is to run as the management account and leave
# org_role_arn / idcaccount_role_arn unset. Set them if Terraform runs from a separate
# automation account that hops in for the Organizations / Identity Center calls (the
# script still needs its own path to the execution role in each account).

provider "aws" {
  region = var.region
}

# AWS Organizations reads (descendant accounts under the OU).
provider "aws" {
  alias  = "org"
  region = var.region

  dynamic "assume_role" {
    for_each = var.org_role_arn == null ? [] : [var.org_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "delegated-iam-tf"
    }
  }
}

# IAM Identity Center: permission-set lookup and customer-managed-policy attachment.
provider "aws" {
  alias  = "idcaccount"
  region = var.region

  dynamic "assume_role" {
    for_each = var.idcaccount_role_arn == null ? [] : [var.idcaccount_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "delegated-iam-tf"
    }
  }
}
