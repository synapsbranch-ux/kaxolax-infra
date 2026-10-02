# Règles WAF de base et limitation de débit. Le jeu « Cloudflare Free Managed Ruleset » est actif
# d'office sur toutes les zones ; le Managed Ruleset complet (plan Pro et plus) s'ajoute par un
# ruleset de phase http_request_firewall_managed. Chaque phase n'a qu'un ruleset d'entrée par
# zone : un ruleset créé depuis le tableau de bord s'importe d'abord (docs/procedure.md).

locals {
  # Méthodes utilisées par l'API (CORS compris).
  api_methods = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

  waf_rules = concat(
    [
      {
        ref         = "block_internal_routes"
        description = "Routes /internal des services : réservées au réseau privé de Railway"
        expression  = "(http.request.uri.path eq \"/internal\" or starts_with(http.request.uri.path, \"/internal/\"))"
      },
      {
        ref         = "api_methods"
        description = "API : méthodes HTTP inconnues refusées"
        expression  = "(http.host eq \"${local.fqdn.api}\" and not http.request.method in {${join(" ", [for m in local.api_methods : "\"${m}\""])}})"
      },
      {
        ref         = "realtime_methods"
        description = "Temps réel : seule la connexion WebSocket (GET) est publique"
        expression  = "(http.host eq \"${local.fqdn.realtime}\" and not http.request.method in {\"GET\" \"HEAD\"})"
      },
    ],
    length(var.admin_allowed_countries) == 0 ? [] : [
      {
        ref         = "admin_countries"
        description = "Admin : pays autorisés seulement"
        expression  = "(http.host eq \"${local.fqdn.admin}\" and not ip.src.country in {${join(" ", [for c in var.admin_allowed_countries : "\"${c}\""])}})"
      },
    ],
  )
}

resource "cloudflare_ruleset" "waf_custom" {
  zone_id     = cloudflare_zone.main.id
  name        = "kaxolax-waf-custom"
  description = "Règles WAF personnalisées de Kaxolax (Terraform)"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [
    for rule in local.waf_rules : {
      ref         = rule.ref
      description = rule.description
      expression  = rule.expression
      action      = "block"
      enabled     = true
    }
  ]
}

resource "cloudflare_ruleset" "rate_limit" {
  zone_id     = cloudflare_zone.main.id
  name        = "kaxolax-rate-limit"
  description = "Limitation de débit de l'API (Terraform)"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [
    for rule in var.rate_limits : {
      ref         = rule.ref
      description = rule.description
      expression  = rule.expression
      action      = "block"
      enabled     = true
      ratelimit = {
        # Par adresse IP et par centre de données Cloudflare (seules caractéristiques du plan Free).
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = rule.period
        requests_per_period = rule.requests_per_period
        mitigation_timeout  = rule.mitigation_timeout
      }
    }
  ]
}
