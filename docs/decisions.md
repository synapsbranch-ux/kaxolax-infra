# Décisions

Chaque décision non triviale : contexte, décision, alternatives écartées (cinq lignes au maximum).

## 2026-09-30 · Deux instances EC2 et Docker Compose pour le staging

- Contexte : le worker doit piloter Docker avec le runtime `runsc` (gVisor), ce qui exclut Fargate. Le staging de l'étape 1 a un worker et une instance applicative.
- Décision : une instance applicative (Caddy, web, api, realtime, compile-gateway, Redis sous Docker Compose) et un worker (agent de compilation), sur Amazon Linux 2023 arm64.
- Écartées : ECS sur EC2 ou EKS, plus de pièces à configurer pour deux machines ; ElastiCache, inutile pour les sessions et verrous d'un staging.

## 2026-09-30 · CloudFront par VPC origin, aucune instance joignable depuis internet

- Contexte : une origine publique en HTTP ferait passer mots de passe et cookies en clair entre CloudFront et l'instance. Le HTTPS vers l'origine exigerait un domaine, que le staging n'a pas forcément.
- Décision : VPC origin sur l'instance applicative, en sous-réseau privé. Depuis mai 2026, les VPC origins acceptent les WebSockets (`/realtime`). Le groupe de sécurité est limité aux plages de CloudFront, et Caddy exige un en-tête secret en plus.
- Écartées : Elastic IP et origine publique (trafic en clair) ; ALB avec certificat ACM (domaine obligatoire, coût).

## 2026-09-30 · Aucun accès à internet depuis le VPC

- Contexte : la règle 9 du sandbox impose un worker sans internet. Garder une passerelle NAT pour la seule instance applicative coûterait ~35 $/mois et ouvrirait une sortie.
- Décision : aucune route par défaut. Endpoints d'interface (ECR, Secrets Manager, SSM, SMTP de SES) dans une zone et endpoint passerelle S3 (dont les dépôts dnf d'AL2023). gVisor et les certificats de RDS sont déposés dans un bucket par `scripts/upload-artifacts.sh`.
- Écartée : NAT limité à l'instance applicative (coût, surface).

## 2026-09-30 · Images officielles par le cache ECR de la galerie ECR Public

- Contexte : sans internet, les instances ne tirent pas Caddy, Redis ni Docker CLI depuis Docker Hub.
- Décision : règle de cache « pull through » d'ECR vers `public.ecr.aws`, qui publie les images officielles de Docker avec les mêmes digests (vérifié pour les trois images épinglées). Pas d'identifiants à gérer.
- Écartées : cache ECR de Docker Hub (identifiants Docker Hub dans Secrets Manager) ; recopie manuelle des images dans ECR.

## 2026-09-30 · Configuration dans S3, secrets dans Secrets Manager, lus au déploiement

- Contexte : des user data qui contiennent la configuration remplacent l'instance à chaque changement, et celles qui contiennent des secrets les exposent (`DescribeInstanceAttribute`).
- Décision : user data fixes (Docker, gVisor, `kaxolax-deploy`). La configuration (fichiers d'environnement, `compose.yml`, `Caddyfile`) est écrite dans S3 par Terraform. Les secrets, générés par Terraform, sont dans Secrets Manager. `kaxolax-deploy` assemble le tout à chaque déploiement.
- Écartée : SSM Parameter Store, limité à 4 Ko par paramètre standard pour les fichiers.

## 2026-09-30 · Mot de passe de RDS généré par Terraform

- Contexte : le mot de passe géré par RDS (`manage_master_user_password`) change à chaque rotation, ce qui casserait les fichiers d'environnement des services.
- Décision : `random_password` alphanumérique (aucun échappement dans les URL ni les fichiers d'environnement), rangé dans Secrets Manager. TLS vérifié avec le certificat de RDS (`DB_SSL=true`, `rds.force_ssl` par défaut en PostgreSQL 18).
- Écartée : authentification IAM de RDS, que ni Lucid ni node-postgres ne gèrent sans code de renouvellement des jetons.

## 2026-09-30 · Registre ECR dans bootstrap

- Contexte : le registre reçoit les images de deux dépôts et doit exister avant le premier apply du staging. Sa destruction échoue tant qu'il contient des images.
- Décision : dépôts ECR et règle de cache dans `bootstrap/`, partagés par les environnements et conservés quand le staging est détruit.

## 2026-09-30 · Docker Compose depuis l'image docker:cli

- Contexte : le paquet `docker` d'Amazon Linux 2023 ne fournit pas le plugin Compose, et le télécharger depuis GitHub est impossible sans internet.
- Décision : `kaxolax-deploy` lance `docker compose` depuis l'image `docker:29.8.1-cli` (Compose 5.5.1, épinglée par digest, via le cache ECR). `/opt/kaxolax` est monté au même chemin, pour que le démon de l'hôte résolve les montages du compose.

## 2026-09-30 · Emails par l'interface SMTP de SES, TLS implicite

- Décision : SMTP de SES par endpoint d'interface, port 465 (`SMTP_SECURE=true`) : TLS obligatoire dès la connexion, aucun repli possible en clair comme avec STARTTLS opportuniste sur 587.
- Tests du staging : réception SES sur `e2e-mail.<domaine>` (MX, règle de réception, bucket S3 de 7 jours), lue par Playwright.

## 2026-09-30 · Worker c7g.xlarge

- Contexte : deux compilations simultanées plafonnées à 2 Go chacune ne tiennent pas dans les 4 Go d'un c7g.large avec le système et l'agent.
- Décision : c7g.xlarge (4 vCPU, 8 Go) et `MAX_CONCURRENT_COMPILES=2`, réglables par variables.

## 2026-09-30 · Terraform installé sans action tierce dans la CI

- Contexte : `registry.terraform.io` et l'API GitHub étaient inaccessibles depuis l'environnement de développement, et l'empreinte d'une version de `hashicorp/setup-terraform` n'a pas pu y être vérifiée.
- Décision : binaire téléchargé depuis `releases.hashicorp.com`, sha256 épinglé dans le workflow. Fichiers de verrouillage avec les empreintes `zh:` de toutes les plateformes, tirées des `SHA256SUMS` signés par HashiCorp (signature vérifiée). tflint n'est pas utilisé ; `terraform test`, avec des fournisseurs simulés, évalue toute la configuration du staging.
