# Test sans compte AWS : fournisseurs simulés, toute la configuration est évaluée (expressions,
# for_each, préconditions, gabarits). Lancer avec : terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
  }
  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name       = "com.amazonaws.eu-west-1.email-smtp"
      availability_zones = ["eu-west-1b", "eu-west-1c"]
    }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { domain_name = "d111111abcdef8.cloudfront.net" }
  }
  mock_resource "aws_instance" {
    defaults = {
      arn         = "arn:aws:ec2:eu-west-1:123456789012:instance/i-0123456789abcdef0"
      private_ip  = "10.40.10.25"
      private_dns = "ip-10-40-10-25.eu-west-1.compute.internal"
    }
  }
  mock_resource "aws_db_instance" {
    defaults = { address = "kaxolax-staging.abcdefghij.eu-west-1.rds.amazonaws.com", port = 5432 }
  }
}

mock_provider "random" {}

variables {
  mail_from_address = "no-reply@example.com"
}

run "staging" {
  command = apply

  assert {
    condition     = output.app_url == "https://d111111abcdef8.cloudfront.net"
    error_message = "L'URL publique doit être celle de CloudFront."
  }

  assert {
    condition = alltrue([
      strcontains(aws_s3_object.app_config["env/api.env"].content, "APP_URL=https://d111111abcdef8.cloudfront.net\n"),
      strcontains(aws_s3_object.app_config["env/api.env"].content, "REALTIME_PUBLIC_URL=wss://d111111abcdef8.cloudfront.net/realtime\n"),
      strcontains(aws_s3_object.app_config["env/api.env"].content, "DB_HOST=kaxolax-staging.abcdefghij.eu-west-1.rds.amazonaws.com\n"),
      strcontains(aws_s3_object.app_config["env/gateway.env"].content, "COMPILE_AGENTS=worker-1=http://10.40.10.25:3200\n"),
      strcontains(aws_s3_object.worker_config["agent.env"].content, "COMPILE_RUNTIME=runsc\n"),
    ])
    error_message = "Configuration des services incomplète."
  }

  # Aucun secret dans la configuration en clair (S3) : ils ne vivent que dans Secrets Manager.
  # Un secret interpolé rendrait le contenu sensible.
  assert {
    condition = alltrue([
      for content in concat(values(aws_s3_object.app_config)[*].content, values(aws_s3_object.worker_config)[*].content) :
      !issensitive(content)
    ])
    error_message = "Un secret apparaît dans la configuration en clair."
  }

  assert {
    condition     = strcontains(aws_s3_object.app_config["compose.yml"].content, "123456789012.dkr.ecr.eu-west-1.amazonaws.com/kaxolax/api:staging")
    error_message = "Le compose doit tirer les images d'ECR."
  }

  assert {
    condition     = !strcontains(aws_s3_object.app_config["compose.yml"].content, "docker.io")
    error_message = "Aucune image ne vient de Docker Hub : les instances n'ont pas accès à internet."
  }
}
