# Jetons R2 au moindre privilège : des jetons de compte (account-owned), indépendants des
# personnes, limités chacun aux buckets qu'il doit lire et écrire. Les identifiants S3 se dérivent
# du jeton (identifiant de clé = id du jeton, secret = SHA-256 de sa valeur), voir outputs.tf.
# Le Worker de compilation n'a pas de jeton : il accède aux buckets par ses bindings R2.

# Groupe de permissions cherché par nom, sauf s'il est fourni (r2_item_write_permission_group_id).
data "cloudflare_account_api_token_permission_groups_list" "all" {
  count = var.r2_item_write_permission_group_id == null ? 1 : 0

  account_id = var.account_id
}

locals {
  # « Object Read & Write » du tableau de bord R2 : lecture, écriture, liste et suppression
  # d'objets, sans gestion des buckets (CORS, cycle de vie, verrou restent à Terraform).
  r2_object_write_group_name = "Workers R2 Storage Bucket Item Write"
  r2_object_write_group_ids = var.r2_item_write_permission_group_id != null ? [var.r2_item_write_permission_group_id] : [
    for group in data.cloudflare_account_api_token_permission_groups_list.all[0].result : group.id
    if group.name == local.r2_object_write_group_name
  ]

  # Ressource d'un bucket dans une politique de jeton : <compte>_<juridiction>_<bucket>.
  bucket_resource = {
    for key, bucket in cloudflare_r2_bucket.main :
    key => "com.cloudflare.edge.r2.bucket.${var.account_id}_${var.r2_jurisdiction}_${bucket.name}"
  }

  r2_tokens = {
    # API (Railway) : fichiers des projets et sorties de compilation (URL présignées, zip).
    app = {
      description = "API Kaxolax sur Railway"
      buckets     = ["project_files", "compile_outputs"]
    }
    # Service de sauvegarde (cron Railway) : dépôt des dumps et test de restauration.
    backup = {
      description = "Sauvegardes PostgreSQL"
      buckets     = ["backups"]
    }
    # CI du dépôt kaxolax-templates : publication de la galerie.
    templates_publish = {
      description = "Publication de la galerie (CI kaxolax-templates)"
      buckets     = ["templates"]
    }
  }
}

resource "cloudflare_account_token" "r2" {
  for_each = local.r2_tokens

  account_id = var.account_id
  name       = "${var.token_name_prefix}-r2-${replace(each.key, "_", "-")}"

  policies = [{
    effect            = "allow"
    permission_groups = [for id in local.r2_object_write_group_ids : { id = id }]
    resources         = jsonencode({ for bucket in each.value.buckets : local.bucket_resource[bucket] => "*" })
  }]

  condition = length(lookup(var.token_allowed_cidrs, each.key, [])) == 0 ? null : {
    request_ip = { in = var.token_allowed_cidrs[each.key] }
  }

  lifecycle {
    precondition {
      condition     = length(local.r2_object_write_group_ids) == 1
      error_message = "Permission group \"Workers R2 Storage Bucket Item Write\" not found (or ambiguous) in this account."
    }
  }
}
