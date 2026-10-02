output "app_url" {
  description = "URL publique du staging (E2E_BASE_URL des tests Playwright)."
  value       = local.app_url
}

output "cloudfront_distribution_id" {
  value = module.cdn.distribution_id
}

output "app_instance_id" {
  description = "Instance applicative (session SSM : aws ssm start-session --target …)."
  value       = module.app.instance_id
}

output "worker_instance_id" {
  value = module.worker.instance_id
}

output "artifacts_bucket" {
  description = "Bucket de gVisor et du certificat de RDS (scripts/upload-artifacts.sh)."
  value       = module.storage.artifacts_bucket
}

output "e2e_mail_domain" {
  description = "Domaine des adresses des tests Playwright du staging (E2E_MAIL_DOMAIN)."
  value       = module.mail.e2e_domain
}

output "e2e_mail_bucket" {
  description = "Bucket des emails reçus par les tests Playwright du staging (E2E_MAIL_S3_BUCKET)."
  value       = module.mail.e2e_bucket
}

output "gvisor_release" {
  description = "Version de gVisor attendue par le worker dans le bucket d'artefacts."
  value       = var.gvisor_release
}
