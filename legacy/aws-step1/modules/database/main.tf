terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "name" {
  type = string
}

variable "subnet_ids" {
  description = "Sous-réseaux privés (deux zones)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Groupe de sécurité de la base (5432 depuis l'instance applicative)."
  type        = string
}

variable "engine_version" {
  description = "Version majeure de PostgreSQL (la dernière mineure disponible est choisie)."
  type        = string
  default     = "18"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "password" {
  description = "Mot de passe de l'utilisateur principal (alphanumérique : sans échappement dans les URL ni les fichiers d'environnement)."
  type        = string
  sensitive   = true
}

variable "deletion_protection" {
  description = "Empêche la suppression de la base (à désactiver pour détruire le staging)."
  type        = bool
  default     = true
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_db_instance" "this" {
  identifier                 = var.name
  engine                     = "postgres"
  engine_version             = var.engine_version
  instance_class             = var.instance_class
  allocated_storage          = 20
  max_allocated_storage      = 100
  storage_type               = "gp3"
  storage_encrypted          = true
  db_name                    = "kaxolax"
  username                   = "kaxolax"
  password                   = var.password
  db_subnet_group_name       = aws_db_subnet_group.this.name
  vpc_security_group_ids     = [var.security_group_id]
  publicly_accessible        = false
  multi_az                   = false
  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.name}-final"
  copy_tags_to_snapshot      = true
}

output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database" {
  value = aws_db_instance.this.db_name
}

output "username" {
  value = aws_db_instance.this.username
}
