# Buckets R2 : fichiers des projets et sorties de compilation (privés, URL présignées par l'API),
# galerie de templates (publique, en lecture seule sur templates.<domaine>, un seul rédacteur :
# la CI de kaxolax-templates), index des packages TeX Live (privé, lu par l'API, écrit par la CI
# de kaxolax-texlive-images), sauvegardes PostgreSQL (privées, verrouillées puis expirées). Les
# URL r2.dev sont désactivées partout.

locals {
  buckets = {
    project_files   = var.bucket_names.project_files
    compile_outputs = var.bucket_names.compile_outputs
    templates       = var.bucket_names.templates
    texlive_index   = var.bucket_names.texlive_index
    backups         = var.bucket_names.backups
  }

  # Les téléversements multipart abandonnés sont facturés : purge après un jour partout.
  abort_multipart_rule = {
    id         = "abort-incomplete-multipart"
    enabled    = true
    conditions = { prefix = "" }
    abort_multipart_uploads_transition = {
      condition = { type = "Age", max_age = 86400 }
    }
  }
}

resource "cloudflare_r2_bucket" "main" {
  for_each = local.buckets

  account_id   = var.account_id
  name         = each.value
  jurisdiction = var.r2_jurisdiction
  location     = var.r2_jurisdiction == "default" ? var.r2_location : null

  lifecycle {
    # Données des utilisateurs et sauvegardes : jamais détruites par un apply.
    prevent_destroy = true
  }
}

resource "cloudflare_r2_managed_domain" "disabled" {
  for_each = local.buckets

  account_id   = var.account_id
  bucket_name  = cloudflare_r2_bucket.main[each.key].name
  jurisdiction = var.r2_jurisdiction
  enabled      = false
}

# Domaine public de la galerie, servi et mis en cache par Cloudflare.
resource "cloudflare_r2_custom_domain" "templates" {
  account_id   = var.account_id
  bucket_name  = cloudflare_r2_bucket.main["templates"].name
  jurisdiction = var.r2_jurisdiction
  zone_id      = cloudflare_zone.main.id
  domain       = local.fqdn.templates
  enabled      = true
  min_tls      = "1.2"
}

# CORS : le navigateur lit et écrit directement par URL présignée.
resource "cloudflare_r2_bucket_cors" "project_files" {
  account_id   = var.account_id
  bucket_name  = cloudflare_r2_bucket.main["project_files"].name
  jurisdiction = var.r2_jurisdiction

  rules = [{
    allowed = {
      origins = [local.app_origin]
      methods = ["GET", "HEAD", "PUT"]
      headers = ["content-type", "content-md5", "x-amz-checksum-crc32", "x-amz-sdk-checksum-algorithm"]
    }
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]
}

resource "cloudflare_r2_bucket_cors" "compile_outputs" {
  account_id   = var.account_id
  bucket_name  = cloudflare_r2_bucket.main["compile_outputs"].name
  jurisdiction = var.r2_jurisdiction

  rules = [{
    allowed = {
      origins = [local.app_origin]
      methods = ["GET", "HEAD"]
      # pdf.js lit le PDF par plages (Range).
      headers = ["range"]
    }
    expose_headers  = ["Accept-Ranges", "Content-Length", "Content-Range", "ETag"]
    max_age_seconds = 3600
  }]
}

# Galerie : miniatures et catalogue lus par l'application, aperçu PDF lu par pdf.js par plages
# (Range) ; sans les en-têtes exposés, pdf.js renonce aux plages et télécharge tout le fichier.
resource "cloudflare_r2_bucket_cors" "templates" {
  account_id   = var.account_id
  bucket_name  = cloudflare_r2_bucket.main["templates"].name
  jurisdiction = var.r2_jurisdiction

  rules = [{
    allowed = {
      origins = [local.app_origin, local.admin_origin]
      methods = ["GET", "HEAD"]
      headers = ["range"]
    }
    expose_headers  = ["Accept-Ranges", "Content-Length", "Content-Range", "ETag"]
    max_age_seconds = 3600
  }]
}

resource "cloudflare_r2_bucket_lifecycle" "backups" {
  account_id   = var.account_id
  bucket_name  = cloudflare_r2_bucket.main["backups"].name
  jurisdiction = var.r2_jurisdiction

  rules = [
    local.abort_multipart_rule,
    {
      id         = "expire-backups"
      enabled    = true
      conditions = { prefix = "" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = var.backup_retention_days * 86400 }
      }
    },
  ]

  lifecycle {
    precondition {
      condition     = var.backup_lock_days < var.backup_retention_days
      error_message = "backup_lock_days must be lower than backup_retention_days, or expired backups could never be deleted."
    }
  }
}

# Verrou : ni suppression ni écrasement d'une sauvegarde récente, même avec un jeton volé.
resource "cloudflare_r2_bucket_lock" "backups" {
  count = var.backup_lock_days > 0 ? 1 : 0

  account_id   = var.account_id
  bucket_name  = cloudflare_r2_bucket.main["backups"].name
  jurisdiction = var.r2_jurisdiction

  rules = [{
    id      = "lock-recent-backups"
    enabled = true
    prefix  = ""
    condition = {
      type            = "Age"
      max_age_seconds = var.backup_lock_days * 86400
    }
  }]
}

# Fichiers des projets (téléversements en attente), sorties de compilation (données des
# utilisateurs : sources envoyées au Worker, PDF), galerie et index TeX Live (sans expiration :
# republiés en entier par leur CI). Mêmes règles qu'en local
# (docker/s3-init/init-buckets.sh de kaxolax-platform).
locals {
  standard_lifecycle_rules = {
    project_files = [{
      id         = "expire-pending-uploads"
      enabled    = true
      conditions = { prefix = "uploads/" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = var.pending_uploads_retention_days * 86400 }
      }
    }]
    compile_outputs = [{
      id         = "expire-compile-outputs"
      enabled    = true
      conditions = { prefix = "" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = var.compile_outputs_retention_days * 86400 }
      }
    }]
    templates     = []
    texlive_index = []
  }
}

resource "cloudflare_r2_bucket_lifecycle" "standard" {
  for_each = local.standard_lifecycle_rules

  account_id   = var.account_id
  bucket_name  = cloudflare_r2_bucket.main[each.key].name
  jurisdiction = var.r2_jurisdiction

  rules = concat([local.abort_multipart_rule], each.value)
}
