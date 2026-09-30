variable "region" {
  description = "Région AWS (SES doit pouvoir y recevoir des emails : eu-west-1 par défaut)."
  type        = string
  default     = "eu-west-1"
}

variable "name" {
  description = "Préfixe des ressources."
  type        = string
  default     = "kaxolax-staging"
}

variable "app_instance_type" {
  description = "Instance applicative : Caddy, web, api, realtime, compile-gateway, Redis."
  type        = string
  default     = "t4g.medium"
}

variable "worker_instance_type" {
  description = "Worker de compilation (Graviton, optimisé calcul) : 4 vCPU et 8 Go pour deux compilations de 2 Go."
  type        = string
  default     = "c7g.xlarge"
}

variable "max_concurrent_compiles" {
  description = "Compilations simultanées sur le worker (2 Go de mémoire et 1 CPU chacune)."
  type        = number
  default     = 2
}

variable "compiles_max_gib" {
  description = "Plafond des répertoires de projets sur le worker, en Gio (les plus anciens sont supprimés)."
  type        = number
  default     = 15
}

variable "cache_max_gib" {
  description = "Plafond du cache des fichiers binaires sur le worker, en Gio."
  type        = number
  default     = 10
}

variable "worker_volume_size" {
  description = "Disque du worker en Go : image TeX Live complète, répertoires des projets et cache."
  type        = number
  default     = 60
}

variable "image_tag" {
  description = "Étiquette des images de la plateforme dans ECR (poussée par la CI de main)."
  type        = string
  default     = "staging"
}

variable "texlive_image_tag" {
  description = "Étiquette de l'image TeX Live dans ECR (schéma full, arm64)."
  type        = string
  default     = "2026-full"
}

variable "gvisor_release" {
  description = "Version de gVisor déposée dans le bucket d'artefacts par scripts/upload-gvisor.sh."
  type        = string
  default     = "20260928.0"
}

variable "mail_from_address" {
  description = "Expéditeur des emails (vérifié dans SES)."
  type        = string
}

variable "mail_domain" {
  description = "Domaine d'envoi géré dans Route 53 (DKIM, réception des emails de test). Vide : adresse seule."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Zone Route 53 de mail_domain."
  type        = string
  default     = ""
}

variable "db_deletion_protection" {
  description = "Protection de la base contre la suppression (false pour détruire le staging)."
  type        = bool
  default     = true
}
