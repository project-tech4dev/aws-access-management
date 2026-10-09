# Create an S3 bucket locked down so only roles inside this AWS
# Organization can read/write it. Everything outside the org is denied.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "bucket_name" {
  description = "Globally-unique bucket name."
  type        = string
}

variable "org_id" {
  description = "AWS Organizations ID (o-xxxx). Only principals in this org get access."
  type        = string
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled; access is policy-only
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1. No plaintext HTTP
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },

      # 2. Block anything not in this organization, whatever else grants it
      {
        Sid       = "DenyAccessOutsideOrg"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
        Condition = { StringNotEquals = { "aws:PrincipalOrgID" = var.org_id } }
      },

      # 3. Grant read/write to IAM roles inside the org (bucket-level listing)
      {
        Sid       = "AllowOrgRolesList"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = aws_s3_bucket.this.arn
        Condition = {
          StringEquals = { "aws:PrincipalOrgID" = var.org_id }
          ArnLike      = { "aws:PrincipalArn" = "arn:aws:iam::*:role/*" }
        }
      },

      # 4. Grant read/write to IAM roles inside the org (object-level)
      {
        Sid       = "AllowOrgRolesReadWrite"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource  = "${aws_s3_bucket.this.arn}/*"
        Condition = {
          StringEquals = { "aws:PrincipalOrgID" = var.org_id }
          ArnLike      = { "aws:PrincipalArn" = "arn:aws:iam::*:role/*" }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

output "bucket_name" {
  value = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}