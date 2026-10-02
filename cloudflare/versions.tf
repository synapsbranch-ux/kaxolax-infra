terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.26.0"
    }
  }

  # État dans un bucket R2 privé créé à la main avant le premier init (voir docs/procedure.md).
  # Configuration partielle : endpoint et nom du bucket dans backend.hcl (non versionné),
  # identifiants R2 par AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key                         = "production/cloudflare.tfstate"
    region                      = "auto"
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    # Verrou natif (fichier .tflock, écriture conditionnelle If-None-Match, gérée par R2).
    use_lockfile = true
  }
}

# Jeton d'API Cloudflare de Terraform : variable d'environnement CLOUDFLARE_API_TOKEN (jamais dans
# un fichier). Permissions nécessaires : docs/procedure.md, « Jeton de Terraform ».
provider "cloudflare" {}
