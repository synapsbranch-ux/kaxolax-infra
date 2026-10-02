terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "name" {
  type = string
}

variable "cors_origins" {
  description = "Origines autorisées à faire un PUT présigné ou à lire le PDF (pdf.js, requêtes Range)."
  type        = list(string)
}

data "aws_caller_identity" "current" {}

locals {
  suffix  = data.aws_caller_identity.current.account_id
  buckets = { project_files = "project-files", compile_outputs = "compile-outputs", artifacts = "artifacts" }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = "${var.name}-${each.value}-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "browser" {
  for_each = { for key, bucket in aws_s3_bucket.this : key => bucket if key != "artifacts" }
  bucket   = each.value.id
  cors_rule {
    allowed_origins = var.cors_origins
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag", "Content-Length", "Content-Range", "Accept-Ranges"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "project_files" {
  bucket = aws_s3_bucket.this["project_files"].id
  rule {
    id     = "expire-pending-uploads"
    status = "Enabled"
    filter {
      prefix = "uploads/"
    }
    expiration {
      days = 1
    }
  }
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "compile_outputs" {
  bucket = aws_s3_bucket.this["compile_outputs"].id
  rule {
    id     = "expire-outputs"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

output "project_files_bucket" {
  value = aws_s3_bucket.this["project_files"].id
}

output "compile_outputs_bucket" {
  value = aws_s3_bucket.this["compile_outputs"].id
}

output "artifacts_bucket" {
  description = "Binaires de gVisor pour le worker, qui n'a pas accès à internet."
  value       = aws_s3_bucket.this["artifacts"].id
}

output "arns" {
  value = { for key, bucket in aws_s3_bucket.this : key => bucket.arn }
}
