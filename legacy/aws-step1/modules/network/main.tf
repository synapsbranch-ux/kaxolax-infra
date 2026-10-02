terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "name" {
  description = "Préfixe des ressources."
  type        = string
}

variable "cidr" {
  description = "Plage d'adresses du VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Nombre de zones de disponibilité (RDS exige deux sous-réseaux privés)."
  type        = number
  default     = 2
}

variable "endpoint_az_count" {
  description = "Zones qui portent les endpoints d'interface (facturés par zone). Les instances du staging sont dans la première."
  type        = number
  default     = 1
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

locals {
  endpoint_subnet_ids = slice(aws_subnet.private[*].id, 0, var.endpoint_az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

# Aucune instance publique, mais CloudFront exige une passerelle internet attachée au VPC pour ses
# VPC origins. Aucune table de routage ne l'utilise.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

# Sous-réseaux privés, sans route vers internet : instance applicative (joignable par CloudFront
# seulement, via une VPC origin), worker de compilation et RDS.
resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr, 8, 10 + count.index)
  tags              = { Name = "${var.name}-private-${local.azs[count.index]}", Tier = "private" }
}

# Aucune route par défaut : ni les workers (règle 9 du sandbox) ni l'instance applicative n'ont
# accès à internet. AWS est joint par les endpoints ci-dessous.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# S3 par endpoint passerelle : fichiers des projets, sorties, couches ECR et dépôts dnf d'AL2023.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.name}-s3" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name}-endpoints"
  description = "HTTPS et SMTPS vers les VPC endpoints depuis le VPC"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints" {
  for_each          = { https = 443, smtps = 465 }
  security_group_id = aws_security_group.endpoints.id
  description       = "${upper(each.key)} depuis le VPC"
  cidr_ipv4         = var.cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# Endpoints d'interface : images ECR, secrets, gestion par SSM (pas de SSH).
resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(["ecr.api", "ecr.dkr", "secretsmanager", "ssm", "ssmmessages", "ec2messages"])
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${var.name}-${each.key}" }
}

# Envoi des emails par l'interface SMTP de SES, disponible dans une partie des zones seulement.
data "aws_vpc_endpoint_service" "smtp" {
  service = "email-smtp"
}

locals {
  smtp_subnet_ids = [
    for index, subnet in aws_subnet.private : subnet.id
    if contains(data.aws_vpc_endpoint_service.smtp.availability_zones, local.azs[index])
  ]
}

resource "aws_vpc_endpoint" "smtp" {
  vpc_id              = aws_vpc.this.id
  service_name        = data.aws_vpc_endpoint_service.smtp.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = slice(local.smtp_subnet_ids, 0, min(var.endpoint_az_count, length(local.smtp_subnet_ids)))
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${var.name}-email-smtp" }

  lifecycle {
    precondition {
      condition     = length(local.smtp_subnet_ids) > 0
      error_message = "Aucune des zones choisies ne propose l'endpoint SMTP de SES."
    }
  }
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "s3_prefix_list_id" {
  description = "Liste de préfixes de S3 (règles de sortie des groupes de sécurité)."
  value       = aws_vpc_endpoint.s3.prefix_list_id
}
