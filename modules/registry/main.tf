terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "repositories" {
  description = "Dépôts ECR (images de la plateforme et image TeX Live)."
  type        = list(string)
  default = [
    "kaxolax/web",
    "kaxolax/api",
    "kaxolax/realtime",
    "kaxolax/compile-gateway",
    "kaxolax/compile-agent",
    "kaxolax-texlive",
  ]
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(var.repositories)
  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = false
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Garder les 30 images les plus récentes"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}

# Cache des images officielles (Caddy, Redis, Docker CLI) depuis la galerie ECR Public, qui publie
# les mêmes digests que Docker Hub : les instances, sans accès à internet, les tirent d'ECR.
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

output "registry" {
  description = "Hôte du registre ECR (compte.dkr.ecr.région.amazonaws.com)."
  value       = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
}

output "arns" {
  value = [for repository in aws_ecr_repository.this : repository.arn]
}
