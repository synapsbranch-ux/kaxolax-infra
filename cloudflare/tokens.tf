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

  # Accès de chaque jeton : buckets en écriture (« Item Write ») et en lecture seule (« Item
  # Read »). R2 ne limite pas un jeton à un préfixe : le plus petit périmètre est le bucket.
  r2_tokens = {
    # API (Railway) : fichiers des projets et sorties de compilation (URL présignées, zip) ; index
    # des packages TeX Live en lecture. La galerie se lit par HTTPS (templates.<domaine>).
    app = {
      description = "API Kaxolax sur Railway"
      write       = ["project_files", "compile_outputs"]
      read        = ["texlive_index"]
    }
    # Service de sauvegarde (cron Railway) : dépôt des dumps et rotation.
    backup = {
      description = "Sauvegardes PostgreSQL"
      write       = ["backups"]
      read        = []
    }
    # Test de restauration (cron facultatif ou poste d'opérateur) : lecture seule. Il détient la
    # clé privée age : sa compromission ne doit pas permettre de supprimer les sauvegardes.
    backup_read = {
      description = "Test de restauration des sauvegardes"
      write       = []
      read        = ["backups"]
    }
    # CI du dépôt kaxolax-templates : publication de la galerie, seul rédacteur de ce bucket public
    # (catalogue, zip importés dans les projets, contenu servi sur templates.<domaine>).
    templates_publish = {
      description = "Publication de la galerie (CI kaxolax-templates)"
      write       = ["templates"]
      read        = []
    }
    # CI de kaxolax-texlive-images : index des packages, dans son bucket privé. R2 ne limite pas un
    # jeton à un préfixe : sur le bucket de la galerie, ce jeton pourrait réécrire le catalogue et
    # ses zip (avec leur sha256), et déposer du contenu sur templates.<domaine>.
    texlive_publish = {
      description = "Index des packages TeX Live (CI kaxolax-texlive-images)"
      write       = ["texlive_index"]
      read        = []
    }
  }

  # Niveaux d'accès utilisés par chaque jeton, écriture d'abord (une politique par niveau).
  r2_token_access = {
    for key, token in local.r2_tokens : key => [for access in ["write", "read"] : access if length(token[access]) > 0]
  }
}

resource "cloudflare_account_token" "r2" {
  for_each = local.r2_tokens

  account_id = var.account_id
  name       = "${var.token_name_prefix}-r2-${replace(each.key, "_", "-")}"

  policies = [
    for access in local.r2_token_access[each.key] : {
      effect            = "allow"
      permission_groups = [for id in local.r2_group_ids[access] : { id = id }]
      resources         = jsonencode({ for bucket in each.value[access] : local.bucket_resource[bucket] => "*" })
    }
  ]

  condition = length(lookup(var.token_allowed_cidrs, each.key, [])) == 0 ? null : {
    request_ip = { in = var.token_allowed_cidrs[each.key] }
  }

  lifecycle {
    precondition {
      condition     = alltrue([for access in local.r2_token_access[each.key] : length(local.r2_group_ids[access]) == 1])
      error_message = "Permission group(s) ${join(", ", [for access in local.r2_token_access[each.key] : "\"${local.r2_permission_groups[access].name}\"" if length(local.r2_group_ids[access]) != 1])} not found (or ambiguous) in this account."
    }
  }
}
