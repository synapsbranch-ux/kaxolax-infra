# Sorties : à reporter chez le registraire (serveurs de noms, DS), dans Railway
# (railway/provision.sh les lit par « terraform output -json ») et dans les CI de
# kaxolax-templates et de kaxolax-texlive-images.

locals {
  templates_base_url = "https://${cloudflare_r2_custom_domain.templates.domain}"
}

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
  description = "URL publique de la galerie (PDF, miniatures, zip) : TEMPLATES_PUBLIC_URL de l'API."
  value       = local.templates_base_url
}

output "templates_catalog_url" {
  description = "Catalogue templates.json publié par kaxolax-templates (à la racine du bucket) : TEMPLATES_CATALOG_URL de l'API."
  value       = "${local.templates_base_url}/templates.json"
}

output "texlive_index" {
  description = "Index des packages TeX Live : bucket et clé où la CI de kaxolax-texlive-images le publie (R2_PUBLIC_BUCKET) et où l'API le lit."
  value = {
    bucket = cloudflare_r2_bucket.main["texlive_index"].name
    key    = var.texlive_index_key
  }
}

# Identifiants S3 par jeton. Sensibles : terraform output -json r2_credentials.
output "r2_credentials" {
  description = "Identifiants S3 par jeton (app, backup, backup_read, templates_publish, texlive_publish) : access_key_id et secret_access_key."
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
  description = "Variables R2 et galerie des services Railway (api, backup, restore_test), clés et valeurs."
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
      # Galerie (catalogue à la racine du bucket public, lu par HTTPS) et index des packages TeX
      # Live (bucket privé, lu avec le jeton app en lecture seule).
      TEMPLATES_CATALOG_URL = "${local.templates_base_url}/templates.json"
      TEMPLATES_PUBLIC_URL  = local.templates_base_url
      TEXLIVE_INDEX_BUCKET  = cloudflare_r2_bucket.main["texlive_index"].name
      TEXLIVE_INDEX_KEY     = var.texlive_index_key
    }
    backup = {
      BACKUP_S3_REGION            = "auto"
      BACKUP_S3_ENDPOINT          = local.r2_s3_endpoint
      BACKUP_S3_BUCKET            = cloudflare_r2_bucket.main["backups"].name
      BACKUP_S3_ACCESS_KEY_ID     = cloudflare_account_token.r2["backup"].id
      BACKUP_S3_SECRET_ACCESS_KEY = sha256(cloudflare_account_token.r2["backup"].value)
    }
    # Test de restauration : jeton en lecture seule sur le même bucket.
    restore_test = {
      BACKUP_S3_REGION            = "auto"
      BACKUP_S3_ENDPOINT          = local.r2_s3_endpoint
      BACKUP_S3_BUCKET            = cloudflare_r2_bucket.main["backups"].name
      BACKUP_S3_ACCESS_KEY_ID     = cloudflare_account_token.r2["backup_read"].id
      BACKUP_S3_SECRET_ACCESS_KEY = sha256(cloudflare_account_token.r2["backup_read"].value)
    }
  }
}
