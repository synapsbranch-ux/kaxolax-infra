# Entrées de la racine Cloudflare. Les valeurs propres à un déploiement vont dans terraform.tfvars
# (ignoré par git) ; aucune n'est secrète : le jeton d'API passe par CLOUDFLARE_API_TOKEN.

variable "account_id" {
  description = "Identifiant du compte Cloudflare (32 caractères hexadécimaux, tableau de bord → Account home)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.account_id))
    error_message = "account_id must be a 32-character lowercase hexadecimal Cloudflare account ID."
  }
}

variable "domain" {
  description = "Domaine de production (zone DNS gérée par Cloudflare), par exemple kaxolax.com."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lowercase domain name such as kaxolax.com."
  }
}

variable "hostnames" {
  description = "Sous-domaines des services Railway et de la galerie (clé : rôle, valeur : étiquette DNS)."
  type = object({
    app       = optional(string, "app")
    admin     = optional(string, "admin")
    api       = optional(string, "api")
    realtime  = optional(string, "realtime")
    templates = optional(string, "templates")
  })
  default = {}

  validation {
    condition = alltrue([
      for label in values(var.hostnames) : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", label))
    ])
    error_message = "Each hostname must be a single lowercase DNS label (no dots)."
  }

  validation {
    condition     = length(distinct(values(var.hostnames))) == length(values(var.hostnames))
    error_message = "Hostnames must be distinct."
  }
}

variable "railway_targets" {
  description = <<-EOT
    Cible CNAME donnée par Railway pour chaque domaine personnalisé (« railway domain <nom> »,
    par exemple abcd1234.up.railway.app), par rôle : app, admin, api, realtime. Un rôle absent ou
    vide ne crée pas d'enregistrement (premier apply avant la création des services Railway).
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for role in keys(var.railway_targets) : contains(["app", "admin", "api", "realtime"], role)])
    error_message = "railway_targets keys must be among: app, admin, api, realtime."
  }

  validation {
    condition = alltrue([
      for target in values(var.railway_targets) : target == "" || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", target))
    ])
    error_message = "railway_targets values must be hostnames (e.g. abcd1234.up.railway.app) or empty."
  }
}

variable "extra_dns_records" {
  description = <<-EOT
    Enregistrements supplémentaires, non proxyfiés : vérification TXT des domaines Railway,
    SPF, DKIM et DMARC de l'expéditeur SMTP, MX. name est relatif à la zone (@ pour l'apex).
  EOT
  type = list(object({
    name     = string
    type     = string
    content  = string
    priority = optional(number)
    ttl      = optional(number, 1)
    comment  = optional(string)
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.extra_dns_records : contains(["TXT", "MX", "CNAME"], r.type)])
    error_message = "extra_dns_records only accepts TXT, MX and CNAME records."
  }

  validation {
    condition     = alltrue([for r in var.extra_dns_records : r.type != "MX" || r.priority != null])
    error_message = "MX records in extra_dns_records need a priority."
  }
}

variable "ssl_mode" {
  description = <<-EOT
    Mode SSL/TLS entre Cloudflare et Railway. « full » le temps que Railway émette les certificats
    de ses domaines personnalisés (premier déploiement), puis « strict » (certificat d'origine vérifié).
  EOT
  type        = string
  default     = "full"

  validation {
    condition     = contains(["full", "strict"], var.ssl_mode)
    error_message = "ssl_mode must be \"full\" or \"strict\" (flexible would send traffic to Railway in clear text)."
  }
}

variable "hsts_max_age" {
  description = "Durée HSTS en secondes (0 désactive l'en-tête). Six mois par défaut, sans preload."
  type        = number
  default     = 15552000

  validation {
    condition     = var.hsts_max_age >= 0 && var.hsts_max_age <= 63072000
    error_message = "hsts_max_age must be between 0 and 63072000 seconds (two years)."
  }
}

variable "enable_dnssec" {
  description = "Active DNSSEC sur la zone. L'enregistrement DS (sortie dnssec_ds) se pose ensuite chez le registraire."
  type        = bool
  default     = true
}

variable "rate_limits" {
  description = <<-EOT
    Règles de limitation de débit (phase http_ratelimit). Le plan Free n'en accepte qu'une, avec
    period = mitigation_timeout = 10, les caractéristiques ip.src et cf.colo.id, et une expression
    sur le chemin seulement ; le plan Pro en accepte deux (une plus stricte sur la compilation).
  EOT
  type = list(object({
    ref                 = string
    description         = string
    expression          = string
    requests_per_period = number
    period              = optional(number, 10)
    mitigation_timeout  = optional(number, 10)
  }))
  default = [{
    ref         = "api_per_ip"
    description = "API : requêtes par adresse IP (webhooks et rappels du Worker exclus)"
    # Chemin seulement (contrainte du plan Free) : couvre api.<domaine>/api/... et la réécriture
    # /api de Next.js sur app.<domaine>. Exclus : webhooks Clerk (rafales depuis peu d'IP) et
    # rappels signés du Worker de compilation (IP de Cloudflare partagées).
    expression          = "(starts_with(http.request.uri.path, \"/api/\") and not starts_with(http.request.uri.path, \"/api/v1/webhooks/\") and not starts_with(http.request.uri.path, \"/api/v1/internal/\"))"
    requests_per_period = 100
  }]

  validation {
    condition     = length(var.rate_limits) >= 1 && length(distinct([for r in var.rate_limits : r.ref])) == length(var.rate_limits)
    error_message = "rate_limits needs at least one rule and unique refs."
  }

  validation {
    condition     = alltrue([for r in var.rate_limits : r.requests_per_period > 0 && contains([10, 60, 120, 300, 600, 3600], r.period)])
    error_message = "rate_limits: requests_per_period must be positive and period one of 10, 60, 120, 300, 600, 3600."
  }
}

variable "admin_allowed_countries" {
  description = "Codes pays ISO (ex. [\"FR\"]) seuls autorisés sur admin.<domaine>. Vide : pas de filtre géographique."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.admin_allowed_countries : can(regex("^[A-Z]{2}$", c))])
    error_message = "admin_allowed_countries must contain ISO 3166-1 alpha-2 codes in upper case."
  }
}

variable "r2_jurisdiction" {
  description = <<-EOT
    Juridiction des buckets R2 : « eu » garantit le stockage dans l'Union européenne (RGPD) ;
    l'endpoint S3 devient https://<compte>.eu.r2.cloudflarestorage.com. Immuable après création.
  EOT
  type        = string
  default     = "eu"

  validation {
    condition     = contains(["default", "eu"], var.r2_jurisdiction)
    error_message = "r2_jurisdiction must be \"default\" or \"eu\"."
  }
}

variable "r2_location" {
  description = "Indication d'emplacement des buckets hors juridiction (ignorée avec r2_jurisdiction = \"eu\")."
  type        = string
  default     = "weur"

  validation {
    condition     = contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], var.r2_location)
    error_message = "r2_location must be one of apac, eeur, enam, weur, wnam, oc."
  }
}

variable "bucket_names" {
  description = "Noms des buckets R2 (globaux au compte). Le bucket de la galerie suit le dépôt kaxolax-templates."
  type = object({
    project_files   = optional(string, "kaxolax-project-files")
    compile_outputs = optional(string, "kaxolax-compile-outputs")
    templates       = optional(string, "kaxolax-templates")
    backups         = optional(string, "kaxolax-backups")
  })
  default = {}

  validation {
    condition     = alltrue([for n in values(var.bucket_names) : can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", n))])
    error_message = "Bucket names must be 3-63 characters: lowercase letters, digits and hyphens."
  }
}

variable "backup_retention_days" {
  description = <<-EOT
    Expiration des sauvegardes PostgreSQL dans R2 (règle de cycle de vie) : filet de sécurité. Le
    job de sauvegarde supprime lui-même les sauvegardes de plus de BACKUP_RETENTION_DAYS jours (35)
    en gardant toujours les BACKUP_MIN_KEEP plus récentes ; cette valeur doit rester supérieure,
    sinon le cycle de vie effacerait aussi les dernières sauvegardes si le job s'arrêtait.
  EOT
  type        = number
  default     = 45

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 3650
    error_message = "backup_retention_days must be between 7 and 3650."
  }
}

variable "backup_lock_days" {
  description = <<-EOT
    Verrou R2 (bucket lock) : une sauvegarde ne peut être ni supprimée ni écrasée pendant ce nombre
    de jours, même avec le jeton du service de sauvegarde. 0 désactive le verrou.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.backup_lock_days >= 0 && var.backup_lock_days <= 365
    error_message = "backup_lock_days must be between 0 and 365."
  }
}

variable "compile_outputs_retention_days" {
  description = "Suppression automatique des sorties de compilation après N jours. null : conservées."
  type        = number
  default     = null

  validation {
    condition     = var.compile_outputs_retention_days == null || try(var.compile_outputs_retention_days >= 1, false)
    error_message = "compile_outputs_retention_days must be null or at least 1."
  }
}

variable "token_allowed_cidrs" {
  description = <<-EOT
    Plages IP autorisées par jeton R2 (clés : app, backup, templates_publish). Vide : pas de
    restriction. Utile pour app et backup avec les IP de sortie statiques de Railway (plan Pro).
  EOT
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.token_allowed_cidrs) : contains(["app", "backup", "templates_publish"], k)])
    error_message = "token_allowed_cidrs keys must be among: app, backup, templates_publish."
  }

  validation {
    condition     = alltrue(flatten([for cidrs in values(var.token_allowed_cidrs) : [for c in cidrs : can(cidrhost(c, 0))]]))
    error_message = "token_allowed_cidrs values must be valid CIDR blocks."
  }
}

variable "token_name_prefix" {
  description = "Préfixe des noms des jetons d'API créés (visible dans le tableau de bord)."
  type        = string
  default     = "kaxolax-production"
}

variable "r2_item_write_permission_group_id" {
  description = <<-EOT
    Identifiant du groupe de permissions « Workers R2 Storage Bucket Item Write ». null : cherché
    par nom dans la liste des groupes du compte (cas normal).
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.r2_item_write_permission_group_id == null || can(regex("^[0-9a-f]{32}$", var.r2_item_write_permission_group_id))
    error_message = "r2_item_write_permission_group_id must be null or a 32-character hexadecimal ID."
  }
}
