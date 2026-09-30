data "aws_caller_identity" "current" {}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  name       = var.name
  account_id = data.aws_caller_identity.current.account_id
  # Registre créé par bootstrap/ (module registry).
  registry = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  app_url  = "https://${module.cdn.domain_name}"

  # Images officielles tirées par le cache ECR de la galerie ECR Public (mêmes digests que Docker Hub).
  public_images = {
    caddy  = "${local.registry}/ecr-public/docker/library/caddy:2.11.4-alpine@sha256:6aeddd44c3078b0f9a35206472a11420648a79c184603ef95957d0a20044cb2b"
    redis  = "${local.registry}/ecr-public/docker/library/redis:8.8.3-alpine@sha256:0b2b77d3ea5078274795e3177cdbdada8b96316684a38911d528534ed679b5ec"
    docker = "${local.registry}/ecr-public/docker/library/docker:29.8.1-cli@sha256:018edbc908e08fcc9dbf029c812c34251e9b4719e6f71ca0e5eae2a987d014ca"
  }
  image = { for service in ["web", "api", "realtime", "compile-gateway", "compile-agent"] :
    service => "${local.registry}/kaxolax/${service}:${var.image_tag}"
  }
  texlive_image = "${local.registry}/kaxolax-texlive:${var.texlive_image_tag}"

  config_prefix = "config"
  artifact_prefixes = {
    app    = ["${local.config_prefix}/app/", "certs/"]
    worker = ["${local.config_prefix}/worker/", "gvisor/"]
  }
  secret_keys = ["app_key", "internal_token", "realtime_token_secret", "origin_verify", "db_password"]
}

module "network" {
  source = "../../modules/network"
  name   = local.name
}

# --- Groupes de sécurité ---

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Instance applicative : HTTP depuis CloudFront seulement"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-app" }
}

# Plages de CloudFront, VPC origins comprises (la règle peut exister avant la VPC origin).
resource "aws_vpc_security_group_ingress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP depuis CloudFront"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_security_group" "worker" {
  name        = "${local.name}-worker"
  description = "Worker de compilation : agent joignable depuis l'instance applicative seulement"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-worker" }
}

resource "aws_vpc_security_group_ingress_rule" "worker_agent" {
  security_group_id            = aws_security_group.worker.id
  description                  = "Agent de compilation depuis le compile-gateway"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3200
  to_port                      = 3200
}

resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "PostgreSQL depuis l'instance applicative"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-database" }
}

resource "aws_vpc_security_group_ingress_rule" "database" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL depuis l'instance applicative"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# Sorties : le VPC (endpoints, base, agent) et S3 par l'endpoint passerelle. Aucune route vers
# internet de toute façon ; ces règles le redisent au niveau des instances.
resource "aws_vpc_security_group_egress_rule" "vpc" {
  for_each = {
    app_tcp    = { group = aws_security_group.app.id, protocol = "tcp", from = 0, to = 65535 }
    worker_tls = { group = aws_security_group.worker.id, protocol = "tcp", from = 443, to = 443 }
  }
  security_group_id = each.value.group
  description       = "Vers le VPC"
  cidr_ipv4         = module.network.vpc_cidr
  ip_protocol       = each.value.protocol
  from_port         = each.value.from
  to_port           = each.value.to
}

resource "aws_vpc_security_group_egress_rule" "s3" {
  for_each          = { app = aws_security_group.app.id, worker = aws_security_group.worker.id }
  security_group_id = each.value
  description       = "HTTPS vers S3 (endpoint passerelle)"
  prefix_list_id    = module.network.s3_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# --- Secrets : générés ici, lus par kaxolax-deploy sur les instances, jamais dans les user data ---

# Alphanumériques : aucun échappement dans les URL ni les fichiers d'environnement.
resource "random_password" "secret" {
  for_each = toset(local.secret_keys)
  length   = 48
  special  = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.name}/app"
  description             = "Secrets des services du staging, lus au déploiement par kaxolax-deploy."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode(merge(
    { for key in local.secret_keys : key => random_password.secret[key].result },
    {
      database_url  = "postgres://${module.database.username}:${random_password.secret["db_password"].result}@${module.database.address}:${module.database.port}/${module.database.database}"
      smtp_username = module.mail.smtp_username
      smtp_password = module.mail.smtp_password
    },
  ))
}

# --- Services managés ---

module "storage" {
  source       = "../../modules/storage"
  name         = local.name
  cors_origins = [local.app_url]
}

module "database" {
  source              = "../../modules/database"
  name                = local.name
  subnet_ids          = module.network.private_subnet_ids
  security_group_id   = aws_security_group.database.id
  password            = random_password.secret["db_password"].result
  deletion_protection = var.db_deletion_protection
}

module "mail" {
  source            = "../../modules/mail"
  name              = local.name
  domain            = var.mail_domain
  route53_zone_id   = var.route53_zone_id
  mail_from_address = var.mail_from_address
}

module "cdn" {
  source               = "../../modules/cdn"
  name                 = local.name
  origin_instance_arn  = module.app.arn
  origin_domain        = module.app.private_dns
  origin_verify_secret = random_password.secret["origin_verify"].result
}

# --- Droits des instances ---

data "aws_iam_policy_document" "instance" {
  for_each = toset(["app", "worker"])

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid     = "EcrPull"
    actions = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = each.key == "app" ? [
      for service in ["web", "api", "realtime", "compile-gateway"] :
      "arn:aws:ecr:${var.region}:${local.account_id}:repository/kaxolax/${service}"
      ] : [
      "arn:aws:ecr:${var.region}:${local.account_id}:repository/kaxolax/compile-agent",
      "arn:aws:ecr:${var.region}:${local.account_id}:repository/kaxolax-texlive",
    ]
  }

  statement {
    sid       = "Secrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]
  }

  # Configuration de l'instance (S3), certificats de RDS (app) ou gVisor (worker).
  statement {
    sid       = "Configuration"
    actions   = ["s3:GetObject"]
    resources = [for prefix in local.artifact_prefixes[each.key] : "${module.storage.arns["artifacts"]}/${prefix}*"]
  }

  statement {
    sid       = "ConfigurationList"
    actions   = ["s3:ListBucket"]
    resources = [module.storage.arns["artifacts"]]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [for prefix in local.artifact_prefixes[each.key] : "${prefix}*"]
    }
  }

  # Worker : lecture des fichiers des projets, écriture des sorties de compilation.
  dynamic "statement" {
    for_each = each.key == "worker" ? [1] : []
    content {
      sid       = "WorkerObjects"
      actions   = ["s3:GetObject"]
      resources = ["${module.storage.arns["project_files"]}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "worker" ? [1] : []
    content {
      sid       = "WorkerOutputs"
      actions   = ["s3:PutObject"]
      resources = ["${module.storage.arns["compile_outputs"]}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "worker" ? [1] : []
    content {
      sid       = "WorkerList"
      actions   = ["s3:ListBucket"]
      resources = [module.storage.arns["project_files"]]
    }
  }

  # Instance applicative : l'API gère les fichiers des projets et lit les sorties de compilation.
  dynamic "statement" {
    for_each = each.key == "app" ? [1] : []
    content {
      sid       = "AppObjects"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${module.storage.arns["project_files"]}/*", "${module.storage.arns["compile_outputs"]}/*"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "app" ? [1] : []
    content {
      sid       = "AppList"
      actions   = ["s3:ListBucket"]
      resources = [module.storage.arns["project_files"], module.storage.arns["compile_outputs"]]
    }
  }

  # Cache ECR Public : le premier tirage crée le dépôt et importe l'image.
  dynamic "statement" {
    for_each = each.key == "app" ? [1] : []
    content {
      sid = "PullThroughCache"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:BatchImportUpstreamImage",
        "ecr:CreateRepository",
        "ecr:GetDownloadUrlForLayer",
      ]
      resources = ["arn:aws:ecr:${var.region}:${local.account_id}:repository/ecr-public/*"]
    }
  }
}

# --- Configuration des instances (S3) : un changement se déploie sans remplacer l'instance ---

locals {
  secret_id = aws_secretsmanager_secret.app.arn
  ca_uri    = "s3://${module.storage.artifacts_bucket}/certs/rds-ca.pem"

  app_config = {
    "deploy.env" = <<-EOT
      REGISTRY=${local.registry}
      SECRET_ID=${local.secret_id}
      CA_URI=${local.ca_uri}
      COMPOSE_IMAGE=${local.public_images.docker}
    EOT
    "compose.yml" = templatefile("${path.module}/templates/compose.yml.tftpl", {
      images        = local.image
      public_images = local.public_images
    })
    "Caddyfile"        = file("${path.module}/files/Caddyfile")
    "env/web.env"      = <<-EOT
      HOSTNAME=0.0.0.0
      PORT=3000
      API_INTERNAL_URL=http://api:3333
    EOT
    "env/api.env"      = <<-EOT
      TZ=UTC
      NODE_ENV=production
      HOST=0.0.0.0
      PORT=3333
      LOG_LEVEL=info
      APP_URL=${local.app_url}
      TRUSTED_PROXY_HOPS=2
      SESSION_DRIVER=redis
      LIMITER_STORE=redis
      DB_HOST=${module.database.address}
      DB_PORT=${module.database.port}
      DB_USER=${module.database.username}
      DB_DATABASE=${module.database.database}
      DB_SSL=true
      NODE_EXTRA_CA_CERTS=/certs/rds-ca.pem
      REDIS_HOST=redis
      REDIS_PORT=6379
      SMTP_HOST=${module.mail.smtp_host}
      SMTP_PORT=465
      SMTP_SECURE=true
      MAIL_FROM_ADDRESS=${var.mail_from_address}
      MAIL_FROM_NAME=Kaxolax
      REALTIME_PUBLIC_URL=wss://${module.cdn.domain_name}/realtime
      REALTIME_INTERNAL_URL=http://realtime:1234
      S3_REGION=${var.region}
      S3_BUCKET_PROJECT_FILES=${module.storage.project_files_bucket}
      S3_BUCKET_COMPILE_OUTPUTS=${module.storage.compile_outputs_bucket}
      COMPILE_GATEWAY_URL=http://compile-gateway:3100
    EOT
    "env/realtime.env" = <<-EOT
      HOST=0.0.0.0
      PORT=1234
      LOG_LEVEL=info
      DB_SSL=true
      NODE_EXTRA_CA_CERTS=/certs/rds-ca.pem
    EOT
    "env/gateway.env"  = <<-EOT
      HOST=0.0.0.0
      PORT=3100
      LOG_LEVEL=info
      REDIS_URL=redis://redis:6379
      COMPILE_AGENTS=worker-1=http://${module.worker.private_ip}:3200
    EOT
    "env/caddy.env"    = <<-EOT
      # Secret de l'en-tête X-Kaxolax-Origin-Verify, ajouté au déploiement.
    EOT
  }

  worker_config = {
    "deploy.env" = <<-EOT
      REGISTRY=${local.registry}
      SECRET_ID=${local.secret_id}
      AGENT_IMAGE=${local.image["compile-agent"]}
      TEXLIVE_IMAGE=${local.texlive_image}
    EOT
    "agent.env"  = <<-EOT
      HOST=0.0.0.0
      PORT=3200
      AGENT_ID=worker-1
      LOG_LEVEL=info
      COMPILE_IMAGE=${local.texlive_image}
      COMPILE_RUNTIME=runsc
      DOCKER_SOCKET=/var/run/docker.sock
      MAX_CONCURRENT_COMPILES=${var.max_concurrent_compiles}
      COMPILES_DIR=/var/lib/kaxolax/compiles
      CACHE_DIR=/var/lib/kaxolax/cache
      COMPILES_MAX_BYTES=${var.compiles_max_gib * 1073741824}
      CACHE_MAX_BYTES=${var.cache_max_gib * 1073741824}
      S3_REGION=${var.region}
      S3_BUCKET_PROJECT_FILES=${module.storage.project_files_bucket}
      S3_BUCKET_COMPILE_OUTPUTS=${module.storage.compile_outputs_bucket}
    EOT
  }
}

# L'instance applicative ne peut pas attendre sa configuration (elle dépend de CloudFront, qui
# dépend de l'instance) : son premier déploiement réessaie jusqu'à ce qu'elle soit là.
resource "aws_s3_object" "app_config" {
  for_each     = local.app_config
  bucket       = module.storage.artifacts_bucket
  key          = "${local.config_prefix}/app/${each.key}"
  content      = each.value
  content_type = "text/plain"
}

resource "aws_s3_object" "worker_config" {
  for_each     = local.worker_config
  bucket       = module.storage.artifacts_bucket
  key          = "${local.config_prefix}/worker/${each.key}"
  content      = each.value
  content_type = "text/plain"
}

# --- Instances ---

module "worker" {
  source             = "../../modules/instance"
  name               = local.name
  role               = "worker"
  instance_type      = var.worker_instance_type
  subnet_id          = module.network.private_subnet_ids[0]
  security_group_ids = [aws_security_group.worker.id]
  root_volume_size   = var.worker_volume_size
  policy_json        = data.aws_iam_policy_document.instance["worker"].json
  user_data = templatefile("${path.module}/templates/worker-user-data.sh.tftpl", {
    region        = var.region
    config_uri    = "s3://${module.storage.artifacts_bucket}/${local.config_prefix}/worker/"
    gvisor_uri    = "s3://${module.storage.artifacts_bucket}/gvisor/${var.gvisor_release}/aarch64/"
    deploy_script = file("${path.module}/files/deploy-worker.sh")
  })

  # Endpoints (ECR, secrets, SSM) et configuration prêts avant le premier démarrage.
  depends_on = [module.network, aws_s3_object.worker_config]
}

module "app" {
  source             = "../../modules/instance"
  name               = local.name
  role               = "app"
  instance_type      = var.app_instance_type
  subnet_id          = module.network.private_subnet_ids[0]
  security_group_ids = [aws_security_group.app.id]
  policy_json        = data.aws_iam_policy_document.instance["app"].json
  user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    region        = var.region
    config_uri    = "s3://${module.storage.artifacts_bucket}/${local.config_prefix}/app/"
    deploy_script = file("${path.module}/files/deploy-app.sh")
  })

  depends_on = [module.network]
}
