terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "name" {
  type = string
}

variable "domain" {
  description = "Domaine d'envoi (identité SES vérifiée par DKIM). Vide : identité email seule."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Zone Route 53 du domaine : enregistrements DKIM et MX créés automatiquement."
  type        = string
  default     = ""
}

variable "mail_from_address" {
  description = "Expéditeur des emails (vérifié par lien si aucun domaine n'est géré ici)."
  type        = string
}

variable "e2e_subdomain" {
  description = "Sous-domaine qui reçoit les emails des tests Playwright du staging (stockés dans S3)."
  type        = string
  default     = "e2e-mail"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  with_domain = var.domain != "" && var.route53_zone_id != ""
  e2e_domain  = local.with_domain ? "${var.e2e_subdomain}.${var.domain}" : ""
  identities  = local.with_domain ? { main = var.domain, e2e = local.e2e_domain } : {}
}

# Identités de domaine, vérifiées par Easy DKIM.
resource "aws_sesv2_email_identity" "domain" {
  for_each       = local.identities
  email_identity = each.value
}

resource "aws_route53_record" "dkim" {
  for_each = local.with_domain ? {
    for pair in setproduct(keys(local.identities), [0, 1, 2]) : "${pair[0]}-${pair[1]}" => {
      identity = pair[0]
      index    = pair[1]
    }
  } : {}
  zone_id = var.route53_zone_id
  name    = "${aws_sesv2_email_identity.domain[each.value.identity].dkim_signing_attributes[0].tokens[each.value.index]}._domainkey.${local.identities[each.value.identity]}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain[each.value.identity].dkim_signing_attributes[0].tokens[each.value.index]}.dkim.amazonses.com"]
}

# Sans domaine géré : l'adresse d'expédition est vérifiée par le lien que SES lui envoie.
resource "aws_sesv2_email_identity" "address" {
  count          = local.with_domain ? 0 : 1
  email_identity = var.mail_from_address
}

# Identifiants SMTP (l'API envoie par SMTP, comme avec Mailpit en local).
resource "aws_iam_user" "smtp" {
  name = "${var.name}-ses-smtp"
}

data "aws_iam_policy_document" "smtp" {
  statement {
    actions   = ["ses:SendRawEmail"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.mail_from_address]
    }
  }
}

resource "aws_iam_user_policy" "smtp" {
  name   = "ses-send"
  user   = aws_iam_user.smtp.name
  policy = data.aws_iam_policy_document.smtp.json
}

resource "aws_iam_access_key" "smtp" {
  user = aws_iam_user.smtp.name
}

# Réception des emails de test : MX vers SES, messages bruts dans un bucket (7 jours).
resource "aws_route53_record" "e2e_mx" {
  count   = local.with_domain ? 1 : 0
  zone_id = var.route53_zone_id
  name    = local.e2e_domain
  type    = "MX"
  ttl     = 600
  records = ["10 inbound-smtp.${data.aws_region.current.region}.amazonaws.com"]
}

resource "aws_s3_bucket" "e2e" {
  count  = local.with_domain ? 1 : 0
  bucket = "${var.name}-e2e-mail-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "e2e" {
  count                   = local.with_domain ? 1 : 0
  bucket                  = aws_s3_bucket.e2e[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "e2e" {
  count  = local.with_domain ? 1 : 0
  bucket = aws_s3_bucket.e2e[0].id
  rule {
    id     = "expire-test-mail"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

data "aws_iam_policy_document" "e2e_bucket" {
  count = local.with_domain ? 1 : 0
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.e2e[0].arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "e2e" {
  count  = local.with_domain ? 1 : 0
  bucket = aws_s3_bucket.e2e[0].id
  policy = data.aws_iam_policy_document.e2e_bucket[0].json
}

resource "aws_ses_receipt_rule_set" "this" {
  count         = local.with_domain ? 1 : 0
  rule_set_name = var.name
}

resource "aws_ses_active_receipt_rule_set" "this" {
  count         = local.with_domain ? 1 : 0
  rule_set_name = aws_ses_receipt_rule_set.this[0].rule_set_name
}

resource "aws_ses_receipt_rule" "e2e" {
  count         = local.with_domain ? 1 : 0
  name          = "store-e2e-mail"
  rule_set_name = aws_ses_receipt_rule_set.this[0].rule_set_name
  recipients    = [local.e2e_domain]
  enabled       = true
  scan_enabled  = true

  s3_action {
    bucket_name       = aws_s3_bucket.e2e[0].id
    object_key_prefix = "inbound/"
    position          = 1
  }

  depends_on = [aws_s3_bucket_policy.e2e]
}

output "smtp_host" {
  value = "email-smtp.${data.aws_region.current.region}.amazonaws.com"
}

output "smtp_username" {
  value = aws_iam_access_key.smtp.id
}

output "smtp_password" {
  value     = aws_iam_access_key.smtp.ses_smtp_password_v4
  sensitive = true
}

output "e2e_domain" {
  description = "Domaine des adresses de test (E2E_MAIL_DOMAIN), vide sans domaine géré."
  value       = local.e2e_domain
}

output "e2e_bucket" {
  description = "Bucket des emails de test reçus (E2E_MAIL_S3_BUCKET)."
  value       = local.with_domain ? aws_s3_bucket.e2e[0].id : ""
}
