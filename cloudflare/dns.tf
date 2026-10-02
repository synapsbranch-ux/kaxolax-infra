# Enregistrements des services Railway : CNAME proxyfiés (CDN, WAF, limitation de débit, TLS de
# Cloudflare). Railway route par l'en-tête Host, conservé par le proxy. Le domaine de la galerie
# (templates.<domaine>) est créé par cloudflare_r2_custom_domain (r2.tf), pas ici.

locals {
  railway_records = {
    for role, target in var.railway_targets : role => target if target != ""
  }
}

resource "cloudflare_dns_record" "railway" {
  for_each = local.railway_records

  zone_id = cloudflare_zone.main.id
  name    = local.fqdn[each.key]
  type    = "CNAME"
  content = each.value
  proxied = true
  ttl     = 1
  comment = "Railway : service ${each.key} (géré par Terraform)"
}

resource "cloudflare_dns_record" "extra" {
  for_each = { for r in var.extra_dns_records : "${r.type}:${r.name}:${sha1(r.content)}" => r }

  zone_id  = cloudflare_zone.main.id
  name     = each.value.name == "@" ? var.domain : "${each.value.name}.${var.domain}"
  type     = each.value.type
  content  = each.value.content
  priority = each.value.priority
  ttl      = each.value.ttl
  proxied  = false
  comment  = coalesce(each.value.comment, "Géré par Terraform")
}
