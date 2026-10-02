# Jetons R2 au moindre privilège : des jetons de compte (account-owned), indépendants des
# personnes, limités chacun aux buckets qu'il doit lire et écrire. Les identifiants S3 se dérivent
# du jeton (identifiant de clé = id du jeton, secret = SHA-256 de sa valeur), voir outputs.tf.
# Le Worker de compilation n'a pas de jeton : il accède aux buckets par ses bindings R2.

# Groupes de permissions cherchés par nom, sauf s'ils sont fournis (r2_item_*_permission_group_id).
data "cloudflare_account_api_token_permission_groups_list" "all" {
  count = var.r2_item_write_permission_group_id == null || var.r2_item_read_permission_group_id == null ? 1 : 0

  account_id = var.account_id
}

locals {
  # « Object Read & Write » du tableau de bord R2 : lecture, écriture, liste et suppression
  # d'objets, sans gestion des buckets (CORS, cycle de vie, verrou restent à Terraform).
  # « Object Read only » : lecture et liste seulement.
  r2_permission_groups = {
    write = { name = "Workers R2 Storage Bucket Item Write", id = var.r2_item_write_permission_group_id }
    read  = { name = "Workers R2 Storage Bucket Item Read", id = var.r2_item_read_permission_group_id }
  }
  r2_group_ids = {
    for access, group in local.r2_permission_groups : access => group.id != null ? [group.id] : [
      for candidate in data.cloudflare_account_api_token_permission_groups_list.all[0].result : candidate.id
      if candidate.name == group.name
    ]
  }

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
      access      = "write"
    }
    # Service de sauvegarde (cron Railway) : dépôt des dumps et rotation.
    backup = {
      description = "Sauvegardes PostgreSQL"
      buckets     = ["backups"]
      access      = "write"
    }
    # Test de restauration (cron facultatif ou poste d'opérateur) : lecture seule. Il détient la
    # clé privée age : sa compromission ne doit pas permettre de supprimer les sauvegardes.
    backup_read = {
      description = "Test de restauration des sauvegardes"
      buckets     = ["backups"]
      access      = "read"
    }
    # CI du dépôt kaxolax-templates : publication de la galerie.
    templates_publish = {
      description = "Publication de la galerie (CI kaxolax-templates)"
      buckets     = ["templates"]
      access      = "write"
    }
  }
}

resource "cloudflare_account_token" "r2" {
  for_each = local.r2_tokens

  account_id = var.account_id
  name       = "${var.token_name_prefix}-r2-${replace(each.key, "_", "-")}"

  policies = [{
    effect            = "allow"
    permission_groups = [for id in local.r2_group_ids[each.value.access] : { id = id }]
    resources         = jsonencode({ for bucket in each.value.buckets : local.bucket_resource[bucket] => "*" })
  }]

  condition = length(lookup(var.token_allowed_cidrs, each.key, [])) == 0 ? null : {
    request_ip = { in = var.token_allowed_cidrs[each.key] }
  }

  lifecycle {
    precondition {
      condition     = length(local.r2_group_ids[each.value.access]) == 1
      error_message = "Permission group \"${local.r2_permission_groups[each.value.access].name}\" not found (or ambiguous) in this account."
    }
  }
}
