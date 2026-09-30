terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "name" {
  type = string
}

variable "origin_instance_arn" {
  description = "Instance applicative (Caddy sur le port 80), dans un sous-réseau privé."
  type        = string
}

variable "origin_domain" {
  description = "Nom DNS privé de l'instance applicative."
  type        = string
}

variable "origin_verify_secret" {
  description = "En-tête ajouté par CloudFront et exigé par Caddy, en plus du groupe de sécurité."
  type        = string
  sensitive   = true
}

variable "origin_read_timeout" {
  description = "Délai de réponse de l'origine (60 s au plus sans augmentation de quota)."
  type        = number
  default     = 60
}

variable "aliases" {
  description = "Noms de domaine personnalisés (certificat ACM en us-east-1 requis)."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

locals {
  # Réponses dynamiques : ni cache ni transformation ; cookies, en-têtes et paramètres transmis.
  dynamic_paths = ["/api/*", "/realtime*"]
}

# VPC origin : CloudFront joint l'instance privée par une interface réseau dans le VPC. Le trafic
# ne traverse pas internet et l'instance n'a pas d'adresse publique.
resource "aws_cloudfront_vpc_origin" "app" {
  vpc_origin_endpoint_config {
    name                   = var.name
    arn                    = var.origin_instance_arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = var.name
  price_class     = "PriceClass_100"
  http_version    = "http2and3"
  aliases         = var.aliases

  origin {
    origin_id   = "app"
    domain_name = var.origin_domain

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.app.id
      origin_read_timeout      = var.origin_read_timeout
      origin_keepalive_timeout = 60
    }

    custom_header {
      name  = "X-Kaxolax-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  # Next.js : tout ce qui n'est pas /api ni /realtime.
  default_cache_behavior {
    target_origin_id           = "app"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  # Fichiers statiques de Next.js : noms versionnés, cache long.
  ordered_cache_behavior {
    path_pattern               = "/_next/static/*"
    target_origin_id           = "app"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  # API REST (/api/*) et WebSocket du temps réel (/realtime).
  dynamic "ordered_cache_behavior" {
    for_each = local.dynamic_paths
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "app"
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods             = ["GET", "HEAD"]
      cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
      response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
      compress                   = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.acm_certificate_arn == ""
    acm_certificate_arn            = var.acm_certificate_arn == "" ? null : var.acm_certificate_arn
    ssl_support_method             = var.acm_certificate_arn == "" ? null : "sni-only"
    minimum_protocol_version       = var.acm_certificate_arn == "" ? "TLSv1" : "TLSv1.2_2021"
  }
}

output "domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}
