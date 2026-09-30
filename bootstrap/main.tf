data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  repo       = { for name in ["kaxolax-platform", "kaxolax-texlive-images", "kaxolax-infra"] : name => "repo:${var.github_owner}/${name}" }
}

# --- État Terraform des environnements (verrouillage natif S3, sans DynamoDB) ---

resource "aws_s3_bucket" "state" {
  bucket = "kaxolax-terraform-state-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Registre ECR : partagé par les environnements, conservé quand le staging est détruit ---

module "registry" {
  source = "../modules/registry"
}

# --- GitHub Actions par OIDC : aucune clé AWS stockée dans GitHub ---

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    # Images poussées depuis main seulement.
    ecr_push = [for name in ["kaxolax-platform", "kaxolax-texlive-images"] : "${local.repo[name]}:ref:refs/heads/main"]
    # Déploiement du staging depuis main de la plateforme.
    deploy = ["${local.repo["kaxolax-platform"]}:ref:refs/heads/main"]
    # Plan en lecture seule sur les PR de l'infra, apply depuis main.
    terraform_plan  = ["${local.repo["kaxolax-infra"]}:pull_request", "${local.repo["kaxolax-infra"]}:ref:refs/heads/main"]
    terraform_apply = ["${local.repo["kaxolax-infra"]}:ref:refs/heads/main"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "github" {
  for_each             = data.aws_iam_policy_document.github_trust
  name                 = "kaxolax-github-${replace(each.key, "_", "-")}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [
      "arn:aws:ecr:${var.region}:${local.account_id}:repository/kaxolax/*",
      "arn:aws:ecr:${var.region}:${local.account_id}:repository/kaxolax-texlive",
    ]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  role   = aws_iam_role.github["ecr_push"].id
  policy = data.aws_iam_policy_document.ecr_push.json
}

# Déploiement : commande SSM sur les instances du projet (docker compose pull && up).
data "aws_iam_policy_document" "deploy" {
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["kaxolax"]
    }
  }
  statement {
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  role   = aws_iam_role.github["deploy"].id
  policy = data.aws_iam_policy_document.deploy.json
}

resource "aws_iam_role_policy_attachment" "terraform_plan" {
  role       = aws_iam_role.github["terraform_plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "terraform_plan_state" {
  role   = aws_iam_role.github["terraform_plan"].id
  policy = data.aws_iam_policy_document.state_access.json
}

# Le rafraîchissement des versions de secrets lit leur valeur (déjà présente dans l'état, que ce
# rôle lit aussi) : ReadOnlyAccess ne l'autorise pas.
data "aws_iam_policy_document" "terraform_plan_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:kaxolax-*"]
  }
}

resource "aws_iam_role_policy" "terraform_plan_secrets" {
  role   = aws_iam_role.github["terraform_plan"].id
  policy = data.aws_iam_policy_document.terraform_plan_secrets.json
}

# L'apply crée VPC, IAM, RDS, CloudFront… : droits d'administration, limités à main de kaxolax-infra.
resource "aws_iam_role_policy_attachment" "terraform_apply" {
  role       = aws_iam_role.github["terraform_apply"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
