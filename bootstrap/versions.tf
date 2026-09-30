terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.67.0"
    }
  }

  # État local : ce dossier crée le bucket d'état lui-même. Appliqué une fois par compte, avec des
  # droits d'administrateur, puis rarement modifié.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "kaxolax"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
