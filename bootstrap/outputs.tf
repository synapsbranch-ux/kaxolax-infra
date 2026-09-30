output "state_bucket" {
  description = "Bucket de l'état Terraform (backend des environnements)."
  value       = aws_s3_bucket.state.id
}

output "github_roles" {
  description = "Rôles à poser dans les variables des repos GitHub (AWS_*_ROLE_ARN)."
  value       = { for key, role in aws_iam_role.github : key => role.arn }
}

output "registry" {
  description = "Hôte du registre ECR (AWS_ECR_REGISTRY)."
  value       = module.registry.registry
}
