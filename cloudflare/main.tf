# Zone DNS de production et réglages TLS. Une zone déjà présente dans le compte s'importe avant le
# premier apply : terraform import cloudflare_zone.main <zone-id>.

locals {
  # Noms complets par rôle (app.kaxolax.com…).
  fqdn = { for role, label in var.hostnames : role => "${label}.${var.domain}" }

  app_origin   = "https://${local.fqdn.app}"
  admin_origin = "https://${local.fqdn.admin}"

  # Endpoint S3 de R2, qui dépend de la juridiction des buckets.
  r2_s3_endpoint = var.r2_jurisdiction == "eu" ? "https://${var.account_id}.eu.r2.cloudflarestorage.com" : "https://${var.account_id}.r2.cloudflarestorage.com"
}

resource "cloudflare_zone" "main" {
  account = { id = var.account_id }
  name    = var.domain
  type    = "full"

  lifecycle {
    # Supprimer la zone effacerait tous les enregistrements et couperait la production.
    prevent_destroy = true
  }
}

resource "cloudflare_zone_dnssec" "main" {
  count = var.enable_dnssec ? 1 : 0

  zone_id = cloudflare_zone.main.id
  status  = "active"
}

# Réglages de sécurité de la zone. « flexible » est exclu par la validation de ssl_mode : le trafic
# vers Railway reste chiffré de bout en bout.
locals {
  zone_settings = {
    ssl                      = var.ssl_mode
    always_use_https         = "on"
    automatic_https_rewrites = "on"
    min_tls_version          = "1.2"
    tls_1_3                  = "on"
    # Service temps réel (Hocuspocus) en WebSocket derrière le proxy.
    websockets = "on"
  }
}

resource "cloudflare_zone_setting" "main" {
  for_each = local.zone_settings

  zone_id    = cloudflare_zone.main.id
  setting_id = each.key
  value      = each.value
}

resource "cloudflare_zone_setting" "hsts" {
  zone_id    = cloudflare_zone.main.id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = var.hsts_max_age > 0
      max_age            = var.hsts_max_age
      include_subdomains = true
      preload            = false
      nosniff            = true
    }
  }
}
