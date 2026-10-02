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

## 2026-10-01 · Railway et Cloudflare remplacent AWS, staging AWS archivé

- Contexte : décision C.2 de l'étape 2 ; pas de staging pour l'instant (C.1).
- Décision : `cloudflare/` (Terraform) et `railway/provision.sh` décrivent la production. Le Terraform AWS de l'étape 1 est déplacé tel quel dans `legacy/aws-step1/`, hors CI, à supprimer une fois le staging détruit.
- Écartée : suppression immédiate, qui empêcherait de détruire proprement un staging encore déployé.

## 2026-10-01 · Railway par sa CLI, pas par Terraform

- Contexte : Railway n'a pas de fournisseur Terraform officiel. Le fournisseur communautaire (terraform-community-providers/railway 0.6.2, avril 2026) ne gère pas les modèles PostgreSQL et Redis et mettrait tous les secrets applicatifs dans l'état ; l'IaC TypeScript de Railway (`railway/iac`, paquet `railway` 3.12) est en bêta, annoncée instable.
- Décision : script bash idempotent sur la CLI officielle (≥ 5.42, sorties `--json`) : crée ce qui manque, ne supprime rien, garde les secrets générés, passe les valeurs par l'entrée standard, `--dry-run`.
- À revoir quand l'IaC de Railway sort de bêta.

## 2026-10-01 · Fournisseur Cloudflare 5.26.0, état dans R2

- Fournisseur officiel `cloudflare/cloudflare` 5.26.0 (26 septembre 2026), seule version épinglée. Fichier de verrouillage : empreinte `h1:` de linux_amd64 et `zh:` de toutes les plateformes, tirées du `SHA256SUMS` de la version (signature GPG non vérifiée faute d'accès au registre depuis l'environnement de développement).
- État : backend `s3` sur un bucket R2 privé créé à la main (l'œuf et la poule), verrou natif `use_lockfile`. Configuration partielle (`backend.hcl` non versionné).
- Écartée : HCP Terraform, un compte et un service de plus.

## 2026-10-01 · R2 en juridiction UE, un jeton de compte par usage

- Données des utilisateurs stockées dans l'UE (`jurisdiction = "eu"`, endpoint `<compte>.eu.r2…`), URL `r2.dev` désactivées.
- Jetons de compte (indépendants des personnes) : `app` (fichiers et sorties), `backup` (sauvegardes), `templates_publish` (galerie), chacun avec le seul groupe « Workers R2 Storage Bucket Item Write » sur ses buckets ; `backup_read` (test de restauration, qui détient la clé privée age) avec « Item Read » seulement ; restriction IP possible. Le Worker passe par ses bindings, sans jeton.
- Écartée : un jeton unique pour tous les buckets (une fuite exposerait tout).

## 2026-10-01 · Sauvegardes : pg_dump vers R2, verrou et cycle de vie

- Service cron Railway (image `scripts/backup/Dockerfile` de kaxolax-platform : PostgreSQL 18.6, rclone 1.75.1 et age 1.3.2 épinglés par empreinte) : `pg_dump` au format custom sur un instantané exporté, archive vérifiée, chiffrée avec age (clé publique seule dans Railway), manifeste (sha256, nombres de lignes), envoi sans jamais réécrire un objet.
- Bucket verrouillé 7 jours (ni suppression ni écrasement, même avec le jeton du service) ; rétention de 35 jours par le job (les 7 dernières toujours gardées), cycle de vie du bucket à 45 jours en filet de sécurité (à 35 jours, il effacerait aussi les dernières sauvegardes si le job s'arrêtait). Test de restauration scripté dans une base jetable, échec si la sauvegarde a plus de 26 h.
- Écartées : sauvegardes de volume de Railway seules (même fournisseur que la base, pas de restauration testée) ; aws-cli (image plus lourde).

## 2026-10-01 · WAF et limitation de débit compatibles avec le plan Free

- Règles personnalisées : `/internal/*` bloqué, méthodes inconnues refusées sur l'API, GET seul sur `realtime`, filtre par pays optionnel sur `admin`. Une règle de débit (100 requêtes par 10 s et par IP sur `/api/*`, hors webhooks et rappels du Worker), expression sur le chemin seulement.
- Liste `rate_limits` en variable : le plan Pro ajoute une règle sur la compilation sans changer le code.

## 2026-10-01 · TLS « full » puis « strict » vers Railway

- Contexte : Railway émet les certificats de ses domaines personnalisés après la création du CNAME ; en `strict`, la première émission échouerait derrière le proxy.
- Décision : `ssl_mode = "full"` au premier déploiement, puis `strict` (procédure, étape 4). `flexible` est refusé par la validation.
