terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.67.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }

  # Bucket créé par bootstrap/ (kaxolax-terraform-state-<compte>), passé à l'init :
  #   terraform init -backend-config="bucket=kaxolax-terraform-state-<compte>"
  # Verrouillage natif S3 (fichier .tflock), sans table DynamoDB.
  backend "s3" {
    key          = "staging/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "kaxolax"
      ManagedBy = "terraform"
      Stack     = "staging"
    }
  }
}
