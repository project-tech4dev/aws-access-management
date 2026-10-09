terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0" # RESOURCE_CONTROL_POLICY support
    }
  }

  # State lives in the AUTOMATION account (never the management account).
  # Backend blocks can't use variables: bucket and region come from
  # backend.hcl (see backend.hcl.example) or, in CI, -backend-config flags.
  backend "s3" {
    key          = "permissions/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # native S3 state locking (Terraform 1.10+); no DynamoDB table needed
  }
}
