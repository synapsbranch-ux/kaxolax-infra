# kaxolax-infra

Infrastructure Terraform de Kaxolax : l'environnement de staging de l'étape 1 sur AWS.

```
bootstrap/          une fois par compte : bucket d'état, rôles GitHub (OIDC), registre ECR
envs/staging/       le staging (réseau, CloudFront, instances, RDS, S3, SES, secrets)
  files/            Caddyfile et kaxolax-deploy (app, worker), testés par shellcheck
  templates/        compose.yml et user data des instances
  tests/            terraform test avec des fournisseurs simulés
modules/            network, cdn, instance, database, storage, registry, mail
scripts/            upload-artifacts.sh (gVisor et certificats de RDS)
```

## Architecture

```
navigateur ──HTTPS──▶ CloudFront ──VPC origin (réseau AWS)──▶ instance app (privée, t4g.medium)
                        │                                     Caddy :80 ─┬─ /api/*      → api
                        │                                                ├─ /realtime*  → realtime (WebSocket)
                        │                                                └─ le reste    → web (Next.js)
                        │                                     compile-gateway, Redis
                        │                                          │ :3200
                        │                                          ▼
                        │                                     worker (privé, c7g.xlarge)
                        │                                     compile-agent → conteneurs TeX Live (runsc)
                        │
   S3 (URL présignées) ◀┘ fichiers des projets, PDF      RDS PostgreSQL 18 (privé)
```

- **Aucune instance n'a accès à internet** : le VPC n'a ni NAT ni route par défaut. ECR, Secrets
  Manager, SSM et l'interface SMTP de SES passent par des endpoints d'interface. S3 (fichiers,
  couches ECR, dépôts dnf d'Amazon Linux) passe par l'endpoint passerelle. C'est la règle 9 du
  sandbox pour le worker, étendue à l'instance applicative.
- **L'instance applicative n'est joignable que par CloudFront** : VPC origin, groupe de sécurité
  limité aux plages de CloudFront, et en-tête secret `X-Kaxolax-Origin-Verify` exigé par Caddy.
- **Compilations** : gVisor (`runsc`) sur le worker, image TeX Live `full` en arm64. Les autres
  règles du sandbox sont appliquées par l'agent (kaxolax-platform) et par l'image
  (kaxolax-texlive-images).
- **Secrets** : générés par Terraform, rangés dans Secrets Manager (`kaxolax-staging/app`), lus à
  chaque déploiement par `kaxolax-deploy`. Ni les user data ni la configuration en clair (S3) n'en
  contiennent ; `terraform test` le vérifie.
- **Configuration** : fichiers d'environnement, `compose.yml` et `Caddyfile` sont des objets S3
  (`config/app/`, `config/worker/`) écrits par Terraform. Les modifier ne remplace pas les
  instances : un `kaxolax-deploy` suffit.
- **Accès aux instances** : Session Manager (`aws ssm start-session --target <id>`), aucun port
  SSH ouvert. IMDSv2 obligatoire.

## Prérequis

- Un compte AWS et des droits d'administration pour le premier `apply`.
- Terraform 1.16.4, AWS CLI v2, `curl`, `sha512sum`.
- Optionnel mais recommandé : un domaine dans Route 53 (DKIM pour SES, et réception des emails des
  tests Playwright du staging).

## Mise en place

1. **Bootstrap** (une fois par compte, état local) :

   ```sh
   cd bootstrap
   terraform init
   terraform apply
   terraform output   # state_bucket, github_roles, registry
   ```

2. **Variables des dépôts GitHub** (Settings → Secrets and variables → Actions → Variables) :

   | Dépôt                    | Variables                                                                                                                                |
   | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
   | `kaxolax-platform`       | `AWS_REGION`, `AWS_ECR_PUSH_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`                                                                             |
   | `kaxolax-texlive-images` | `AWS_REGION`, `AWS_ECR_PUSH_ROLE_ARN`                                                                                                    |
   | `kaxolax-infra`          | `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_TERRAFORM_PLAN_ROLE_ARN`, `AWS_TERRAFORM_APPLY_ROLE_ARN`, `MAIL_FROM_ADDRESS` (`MAIL_DOMAIN`, `ROUTE53_ZONE_ID`) |

   Puis relancer les workflows de `main` de `kaxolax-texlive-images` et de `kaxolax-platform` : ils
   poussent les images dans ECR (`kaxolax-texlive:2026-full`, `kaxolax/*:staging`).

3. **Staging**, en deux temps : le worker a besoin de gVisor dans le bucket d'artefacts dès son
   premier démarrage.

   ```sh
   cd envs/staging
   cp terraform.tfvars.example terraform.tfvars      # expéditeur, domaine éventuel
   terraform init -backend-config="bucket=$(terraform -chdir=../../bootstrap output -raw state_bucket)"
   terraform apply -target=module.storage
   ../../scripts/upload-artifacts.sh "$(terraform output -raw artifacts_bucket)" "$(terraform output -raw gvisor_release)"
   terraform apply
   ```

   Ensuite, `terraform apply` tourne dans la CI de ce dépôt (environnement GitHub `staging`).

4. **SES** : sans domaine géré, confirmer l'adresse d'expédition par le lien reçu. Tant que le
   compte est dans le bac à sable SES, seules les adresses et domaines vérifiés reçoivent des
   emails (le domaine `e2e-mail.<domaine>` des tests l'est). Demander l'accès production à SES pour
   de vrais utilisateurs.

5. **Déploiement** : les instances lancent `kaxolax-deploy` au démarrage, et le réessaient tant que
   la configuration ou les images manquent. Ensuite, chaque push sur `main` de `kaxolax-platform`
   pousse les images et déploie par SSM. À la main :

   ```sh
   aws ssm send-command --document-name AWS-RunShellScript \
     --targets Key=tag:Project,Values=kaxolax Key=tag:Stack,Values=staging \
     --parameters 'commands=["/usr/local/bin/kaxolax-deploy"]'
   ```

## Vérifications

```sh
terraform fmt -check -recursive
terraform -chdir=bootstrap init -backend=false && terraform -chdir=bootstrap validate
terraform -chdir=envs/staging init -backend=false && terraform -chdir=envs/staging validate
terraform -chdir=envs/staging test        # fournisseurs simulés, sans compte AWS
shellcheck scripts/*.sh envs/staging/files/*.sh
```

Sur le staging déployé :

```sh
cd ../kaxolax-platform/apps/web
E2E_BASE_URL="$(terraform -chdir=../../../kaxolax-infra/envs/staging output -raw app_url)" \
E2E_MAIL_DOMAIN="$(terraform -chdir=../../../kaxolax-infra/envs/staging output -raw e2e_mail_domain)" \
E2E_MAIL_S3_BUCKET="$(terraform -chdir=../../../kaxolax-infra/envs/staging output -raw e2e_mail_bucket)" \
  pnpm test:e2e
```

## Limites connues

- **Délai de réponse de CloudFront** : 60 s par défaut, autant que le délai de compilation. Une
  compilation qui atteint la limite peut répondre 504 côté navigateur alors qu'elle se termine
  sur le worker. Demander l'augmentation du quota « Response timeout per origin » (jusqu'à 180 s)
  puis régler `origin_read_timeout` du module `cdn`.
- **Un seul worker** et une seule instance applicative, dans une zone : pas de haute
  disponibilité pour le staging.
- **Destruction** : passer `db_deletion_protection = false`, appliquer, puis `terraform destroy`.
  Le registre ECR (bootstrap) est conservé.

## Coût indicatif (eu-west-1, à la demande)

Instance app t4g.medium ~25 $/mois, worker c7g.xlarge ~105 $/mois, RDS db.t4g.micro ~15 $/mois,
7 endpoints d'interface dans une zone ~55 $/mois, plus CloudFront, S3 et SES à l'usage.
