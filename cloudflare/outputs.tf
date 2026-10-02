# Sorties : à reporter chez le registraire (serveurs de noms, DS), dans Railway
# (railway/provision.sh les lit par « terraform output -json ») et dans la CI de kaxolax-templates.

output "zone_id" {
  description = "Identifiant de la zone (wrangler.jsonc du Worker de compilation, routes)."
  value       = cloudflare_zone.main.id
}

output "name_servers" {
  description = "Serveurs de noms Cloudflare à déclarer chez le registraire du domaine."
  value       = cloudflare_zone.main.name_servers
}

output "dnssec_ds" {
  description = "Enregistrement DS à poser chez le registraire (null si DNSSEC est désactivé)."
  value       = var.enable_dnssec ? cloudflare_zone_dnssec.main[0].ds : null
}

output "hostnames" {
  description = "Noms complets par rôle (app, admin, api, realtime, templates)."
  value       = local.fqdn
}

output "r2_s3_endpoint" {
  description = "Endpoint S3 de R2 pour les buckets de cette configuration."
  value       = local.r2_s3_endpoint
}

output "r2_buckets" {
  description = "Noms des buckets R2 par rôle (bindings du Worker de compilation, variables des services)."
  value       = { for key, bucket in cloudflare_r2_bucket.main : key => bucket.name }
}

output "r2_jurisdiction" {
  description = "Juridiction des buckets (champ jurisdiction des bindings R2 du Worker)."
  value       = var.r2_jurisdiction
}

output "templates_public_url" {
  description = "URL publique de la galerie (catalogue templates.json, PDF, miniatures, zip)."
  value       = "https://${cloudflare_r2_custom_domain.templates.domain}"
}

# Identifiants S3 par jeton. Sensibles : terraform output -json r2_credentials.
output "r2_credentials" {
  description = "Identifiants S3 par jeton (app, backup, templates_publish) : access_key_id et secret_access_key."
  sensitive   = true
  value = {
    for key, token in cloudflare_account_token.r2 : key => {
      access_key_id     = token.id
      secret_access_key = sha256(token.value)
    }
  }
}

# Variables d'environnement prêtes à poser dans Railway, lues par railway/provision.sh.
output "railway_variables" {
  description = "Variables S3/R2 des services Railway (api, backup), clés et valeurs."
  sensitive   = true
  value = {
    api = {
      S3_REGION                 = "auto"
      S3_ENDPOINT               = local.r2_s3_endpoint
      S3_PUBLIC_ENDPOINT        = local.r2_s3_endpoint
      S3_FORCE_PATH_STYLE       = "true"
      S3_ACCESS_KEY_ID          = cloudflare_account_token.r2["app"].id
      S3_SECRET_ACCESS_KEY      = sha256(cloudflare_account_token.r2["app"].value)
      S3_BUCKET_PROJECT_FILES   = cloudflare_r2_bucket.main["project_files"].name
      S3_BUCKET_COMPILE_OUTPUTS = cloudflare_r2_bucket.main["compile_outputs"].name
      TEMPLATES_BASE_URL        = "https://${cloudflare_r2_custom_domain.templates.domain}"
    }
    backup = {
      BACKUP_S3_REGION            = "auto"
      BACKUP_S3_ENDPOINT          = local.r2_s3_endpoint
      BACKUP_S3_BUCKET            = cloudflare_r2_bucket.main["backups"].name
      BACKUP_S3_ACCESS_KEY_ID     = cloudflare_account_token.r2["backup"].id
      BACKUP_S3_SECRET_ACCESS_KEY = sha256(cloudflare_account_token.r2["backup"].value)
    }
  }
}
