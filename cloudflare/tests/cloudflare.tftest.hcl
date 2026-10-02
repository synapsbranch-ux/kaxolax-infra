# Tests sans compte Cloudflare : fournisseur simulé, plans seulement (la zone et les buckets ont
# prevent_destroy). terraform -chdir=cloudflare test

# Valeurs simulées dès le plan (attributs calculés : identifiants, valeurs des jetons).
mock_provider "cloudflare" {
  override_during = plan
}

# La recherche du groupe de permissions par nom (liste imbriquée) n'est pas simulable par
# override_data : l'identifiant est fourni, et le dernier test couvre la recherche sans résultat.
variables {
  account_id                        = "0123456789abcdef0123456789abcdef"
  domain                            = "kaxolax.test"
  r2_item_write_permission_group_id = "bf7481a1826f439697cb59a20b22293e"
  r2_item_read_permission_group_id  = "b4992e1108244f5d8bfbd5744320c2e1"
}

run "defaults" {
  command = plan

  assert {
    condition     = length(cloudflare_r2_bucket.main) == 4 && alltrue([for b in cloudflare_r2_bucket.main : b.jurisdiction == "eu"])
    error_message = "Four R2 buckets in the EU jurisdiction are expected."
  }

  assert {
    condition     = cloudflare_r2_bucket.main["templates"].name == "kaxolax-templates"
    error_message = "The gallery bucket must match the kaxolax-templates publishing workflow."
  }

  assert {
    condition     = alltrue([for d in cloudflare_r2_managed_domain.disabled : d.enabled == false])
    error_message = "r2.dev public URLs must be disabled on every bucket."
  }

  assert {
    condition     = cloudflare_r2_custom_domain.templates.domain == "templates.kaxolax.test" && cloudflare_r2_custom_domain.templates.min_tls == "1.2"
    error_message = "The gallery must be public on templates.<domain> with TLS 1.2 or later."
  }

  assert {
    condition     = length(cloudflare_dns_record.railway) == 0
    error_message = "No Railway record before the Railway targets are known."
  }

  assert {
    condition     = output.r2_s3_endpoint == "https://0123456789abcdef0123456789abcdef.eu.r2.cloudflarestorage.com"
    error_message = "EU buckets use the eu R2 endpoint."
  }

  assert {
    condition     = cloudflare_zone_setting.main["ssl"].value == "full" && cloudflare_zone_setting.main["min_tls_version"].value == "1.2"
    error_message = "TLS settings are wrong."
  }

  # Moindre privilège : chaque jeton ne vise que ses buckets, avec un seul groupe « Item Write »
  # (ou « Item Read » pour le test de restauration).
  assert {
    condition = cloudflare_account_token.r2["app"].policies[0].resources == jsonencode({
      "com.cloudflare.edge.r2.bucket.0123456789abcdef0123456789abcdef_eu_kaxolax-project-files"   = "*"
      "com.cloudflare.edge.r2.bucket.0123456789abcdef0123456789abcdef_eu_kaxolax-compile-outputs" = "*"
    })
    error_message = "The app token must only reach the project files and compile outputs buckets."
  }

  assert {
    condition = cloudflare_account_token.r2["backup"].policies[0].resources == jsonencode({
      "com.cloudflare.edge.r2.bucket.0123456789abcdef0123456789abcdef_eu_kaxolax-backups" = "*"
    })
    error_message = "The backup token must only reach the backups bucket."
  }

  assert {
    condition = cloudflare_account_token.r2["templates_publish"].policies[0].resources == jsonencode({
      "com.cloudflare.edge.r2.bucket.0123456789abcdef0123456789abcdef_eu_kaxolax-templates" = "*"
    })
    error_message = "The templates token must only reach the gallery bucket."
  }

  assert {
    condition = cloudflare_account_token.r2["backup_read"].policies[0].resources == jsonencode({
      "com.cloudflare.edge.r2.bucket.0123456789abcdef0123456789abcdef_eu_kaxolax-backups" = "*"
    })
    error_message = "The restore test token must only reach the backups bucket."
  }

  assert {
    condition     = alltrue([for k, t in cloudflare_account_token.r2 : length(t.policies) == 1 && length(t.policies[0].permission_groups) == 1 && t.policies[0].permission_groups[0].id == (k == "backup_read" ? var.r2_item_read_permission_group_id : var.r2_item_write_permission_group_id)])
    error_message = "R2 tokens must only carry one bucket item permission group (read only for the restore test)."
  }

  assert {
    condition     = alltrue([for t in cloudflare_account_token.r2 : t.condition == null])
    error_message = "No IP restriction by default."
  }

  assert {
    condition     = length(cloudflare_r2_bucket_lock.backups) == 1 && cloudflare_r2_bucket_lock.backups[0].rules[0].condition.max_age_seconds == 7 * 86400
    error_message = "Recent backups must be locked for seven days."
  }

  assert {
    condition     = cloudflare_r2_bucket_lifecycle.backups.rules[1].delete_objects_transition.condition.max_age == 45 * 86400
    error_message = "Backups must expire after 45 days (safety net beyond the job retention)."
  }

  assert {
    condition     = length(cloudflare_r2_bucket_lifecycle.standard["compile_outputs"].rules) == 1
    error_message = "Compile outputs are kept by default."
  }

  assert {
    condition     = length(cloudflare_ruleset.waf_custom.rules) == 3 && cloudflare_ruleset.waf_custom.rules[0].action == "block"
    error_message = "Three base WAF rules are expected without a country filter."
  }

  assert {
    condition     = cloudflare_ruleset.rate_limit.rules[0].ratelimit.period == 10 && cloudflare_ruleset.rate_limit.rules[0].ratelimit.requests_per_period == 100
    error_message = "The default rate limit must fit the Free plan (10 s period)."
  }
}

run "railway_records_and_options" {
  command = plan

  variables {
    railway_targets = {
      app      = "app123.up.railway.app"
      api      = "api123.up.railway.app"
      realtime = "rt123.up.railway.app"
      admin    = ""
    }
    extra_dns_records = [
      { name = "_railway-verify.app", type = "TXT", content = "railway-verify=abc" },
      { name = "@", type = "MX", content = "mx.example.net", priority = 10 },
    ]
    admin_allowed_countries        = ["FR", "BE"]
    token_allowed_cidrs            = { backup = ["203.0.113.0/24"] }
    compile_outputs_retention_days = 90
    r2_jurisdiction                = "default"
    enable_dnssec                  = false
  }

  assert {
    condition     = length(cloudflare_dns_record.railway) == 3 && alltrue([for r in cloudflare_dns_record.railway : r.proxied && r.type == "CNAME"])
    error_message = "One proxied CNAME per non-empty Railway target."
  }

  assert {
    condition     = cloudflare_dns_record.railway["api"].name == "api.kaxolax.test" && cloudflare_dns_record.railway["api"].content == "api123.up.railway.app"
    error_message = "The API record must point to its Railway target."
  }

  assert {
    condition     = length(cloudflare_dns_record.extra) == 2 && alltrue([for r in cloudflare_dns_record.extra : !r.proxied])
    error_message = "Extra records are created unproxied."
  }

  assert {
    condition     = length(cloudflare_ruleset.waf_custom.rules) == 4 && strcontains(cloudflare_ruleset.waf_custom.rules[3].expression, "ip.src.country in {\"FR\" \"BE\"}")
    error_message = "The admin country filter must be added."
  }

  assert {
    condition     = cloudflare_account_token.r2["backup"].condition.request_ip.in[0] == "203.0.113.0/24" && cloudflare_account_token.r2["app"].condition == null
    error_message = "IP restrictions apply per token."
  }

  assert {
    condition     = length(cloudflare_r2_bucket_lifecycle.standard["compile_outputs"].rules) == 2
    error_message = "Compile outputs retention rule must be added."
  }

  assert {
    condition     = cloudflare_r2_bucket.main["backups"].location == "weur" && output.r2_s3_endpoint == "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"
    error_message = "Default jurisdiction uses the location hint and the global endpoint."
  }

  assert {
    condition     = length(cloudflare_zone_dnssec.main) == 0 && output.dnssec_ds == null
    error_message = "DNSSEC must be optional."
  }
}

run "rejects_flexible_ssl" {
  command = plan

  variables {
    ssl_mode = "flexible"
  }

  expect_failures = [var.ssl_mode]
}

run "rejects_unknown_railway_role" {
  command = plan

  variables {
    railway_targets = { web = "x.up.railway.app" }
  }

  expect_failures = [var.railway_targets]
}

run "rejects_lock_longer_than_retention" {
  command = plan

  variables {
    backup_lock_days      = 30
    backup_retention_days = 30
  }

  expect_failures = [cloudflare_r2_bucket_lifecycle.backups]
}

run "fails_without_r2_permission_group" {
  command = plan

  # Liste simulée vide : le groupe n'est pas trouvé.
  variables {
    r2_item_write_permission_group_id = null
  }

  expect_failures = [cloudflare_account_token.r2]
}

run "fails_without_r2_read_permission_group" {
  command = plan

  variables {
    r2_item_read_permission_group_id = null
  }

  expect_failures = [cloudflare_account_token.r2]
}
