terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "name" {
  type = string
}

variable "role" {
  description = "Rôle de l'instance (app, worker) : étiquette Role et nom des ressources."
  type        = string
}

variable "instance_type" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "root_volume_size" {
  type    = number
  default = 30
}

variable "user_data" {
  description = "Script de premier démarrage (16 Ko au plus). La configuration vit dans S3 : la modifier ne remplace pas l'instance."
  type        = string
}

variable "policy_json" {
  description = "Droits de l'instance (ECR, S3, secrets…), en plus de la gestion par SSM."
  type        = string
}

# Amazon Linux 2023, arm64 (instances Graviton).
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-${var.role}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Accès par Session Manager : aucun port SSH ouvert.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-${var.role}"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-${var.role}"
  role = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false
  user_data                   = var.user_data
  user_data_replace_on_change = true

  # IMDSv2 obligatoire ; deux sauts pour que les conteneurs obtiennent les droits de l'instance.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  lifecycle {
    ignore_changes = [ami]
    precondition {
      condition     = length(var.user_data) <= 16384
      error_message = "Les user data d'une instance EC2 sont limitées à 16 Ko."
    }
  }

  tags = { Name = "${var.name}-${var.role}", Role = var.role }
}

output "instance_id" {
  value = aws_instance.this.id
}

output "arn" {
  value = aws_instance.this.arn
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "private_dns" {
  value = aws_instance.this.private_dns
}

