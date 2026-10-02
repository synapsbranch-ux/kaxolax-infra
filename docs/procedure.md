# Procédure de mise en production

Dans l'ordre. Rien n'est appliqué automatiquement : chaque étape est lancée par l'opérateur.
Commandes depuis la racine de ce dépôt, sauf mention contraire.

## 0. Prérequis

- Comptes : Cloudflare (Workers Paid pour Containers et Durable Objects), Railway (plan Pro
  conseillé), GitHub (dépôts kaxolax-platform, kaxolax-infra, kaxolax-templates), Clerk (instance
  de production), fournisseur SMTP.
- Domaine enregistré chez un registraire qui accepte DNSSEC.
- Outils : Terraform 1.16.4, CLI Railway ≥ 5.42, `jq`, `openssl`, `docker`, `age` ; dans
  kaxolax-platform : `pnpm` (wrangler y est une dépendance).

## 1. État Terraform et jeton de Terraform (une fois)

1. Tableau de bord Cloudflare → R2 → créer le bucket **`kaxolax-terraform-state`** (juridiction
   UE), sans accès public.
2. R2 → « Manage API tokens » → jeton de compte, permission « Object Read & Write » limitée à
   `kaxolax-terraform-state`. Noter l'identifiant de clé et le secret S3.
3. API Tokens → jeton de compte pour Terraform, avec au minimum :
   - compte : « Account API Tokens Write » (création des jetons R2), « Workers R2 Storage Write »,
     « Account Settings Read » ;
   - zone (la zone de production, ou toutes les zones du compte pour la créer) : « Zone Write »,
     « Zone Settings Write », « DNS Write », « Zone WAF Write », « SSL and Certificates Write ».
4. Configuration locale (jamais commitée) :

   ```sh
   cp cloudflare/backend.hcl.example cloudflare/backend.hcl         # endpoint du compte
   cp cloudflare/terraform.tfvars.example cloudflare/terraform.tfvars
   export CLOUDFLARE_API_TOKEN=…            # jeton de Terraform
   export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…   # jeton du bucket d'état
   ```

## 2. Cloudflare : zone, buckets, jetons

```sh
terraform -chdir=cloudflare init -backend-config=backend.hcl
terraform -chdir=cloudflare plan
terraform -chdir=cloudflare apply
terraform -chdir=cloudflare output name_servers dnssec_ds
```

- Zone déjà présente dans le compte : `terraform -chdir=cloudflare import cloudflare_zone.main <zone-id>`
  avant l'apply. Ruleset WAF ou de limitation de débit déjà créé depuis le tableau de bord :
  `terraform import 'cloudflare_ruleset.waf_custom' 'zones/<zone-id>/<ruleset-id>'` (idem pour
  `rate_limit`).
- Chez le registraire : remplacer les serveurs de noms par `name_servers`, puis poser
  l'enregistrement DS (`dnssec_ds`) une fois la zone active.
- Au premier apply, `railway_targets` est vide : aucun enregistrement vers Railway n'est créé.

## 3. Worker et Containers de compilation (kaxolax-platform)

Valeurs à reporter dans la configuration wrangler du Worker :

```sh
terraform -chdir=cloudflare output r2_buckets r2_jurisdiction zone_id
```

- Bindings R2 : `project_files` et `compile_outputs`, avec `jurisdiction = "eu"`.
- Domaine `compile.<domaine>` déclaré comme domaine personnalisé du Worker dans sa configuration
  wrangler (wrangler crée l'enregistrement ; Terraform n'en gère pas sur ce nom).
- Secret partagé avec l'API, posé après l'étape 4 :
  `railway variable list --service api --kv | grep '^COMPILE_WORKER_SECRET='` puis
  `pnpm wrangler secret put COMPILE_WORKER_SECRET`.
- Déploiement : `pnpm wrangler deploy` (jeton créé depuis le modèle « Edit Cloudflare Workers »,
  avec la permission Containers en écriture). Ce jeton n'est pas créé par Terraform.

## 4. Railway : projet, services, variables, domaines

1. Railway → Account → Tokens : jeton de **workspace** ; GitHub : installer l'application Railway
   sur kaxolax-platform et kaxolax-infra.
2. Le Dockerfile de kaxolax-platform doit choisir son étape finale avec l'argument de build
   `KAXOLAX_SERVICE` (web, admin, api, realtime), posé comme variable de chaque service.
3. Lancer le provisionnement (d'abord à blanc) :

   ```sh
   export RAILWAY_API_TOKEN=… RAILWAY_WORKSPACE=… \
     PLATFORM_REPO=<owner>/kaxolax-platform INFRA_REPO=<owner>/kaxolax-infra \
     COMPILE_WORKER_URL=https://compile.<domaine>
   # Secrets fournis par l'opérateur (gestionnaire de mots de passe), jamais dans un fichier :
   export CLERK_PUBLISHABLE_KEY=… CLERK_SECRET_KEY=… CLERK_JWT_KEY=… CLERK_WEBHOOK_SIGNING_SECRET=… \
     SMTP_HOST=… SMTP_PORT=465 SMTP_SECURE=true SMTP_USERNAME=… SMTP_PASSWORD=… \
     MAIL_FROM_ADDRESS=… MAIL_FROM_NAME=Kaxolax
   railway/provision.sh --dry-run
   railway/provision.sh
   ```

   Le script crée ce qui manque (projet, PostgreSQL, Redis, services web, admin, api, realtime,
   backup), pose les variables sans redéployer, règle Dockerfile, healthchecks, migrations
   (pré-déploiement de l'API) et cron de sauvegarde, puis ajoute les domaines personnalisés.
   Relancé, il ne recrée rien et garde les secrets générés (APP_KEY, REALTIME_TOKEN_SECRET,
   INTERNAL_TOKEN, COMPILE_WORKER_SECRET).
4. Reporter les cibles affichées (« enregistrements DNS demandés par Railway ») dans
   `cloudflare/terraform.tfvars` : CNAME dans `railway_targets`, TXT de vérification éventuels
   dans `extra_dns_records`. Puis `terraform -chdir=cloudflare apply`.
5. Attendre les certificats (`railway domain status <nom> --service <service>`), puis
   `ssl_mode = "strict"` et `terraform -chdir=cloudflare apply`.
6. Déployer : `railway redeploy --service <service>` pour chacun (ou un push sur `main`).

Services `admin` absents de la plateforme au moment du provisionnement : `SERVICES="web api
realtime backup" railway/provision.sh`.

## 5. Galerie de templates (kaxolax-templates)

```sh
terraform -chdir=cloudflare output -json r2_credentials | jq '.templates_publish'
terraform -chdir=cloudflare output r2_s3_endpoint templates_public_url
```

Dans le dépôt kaxolax-templates (environnement GitHub `templates`, branche `main` seulement) :
variables `R2_ENDPOINT` (endpoint), `R2_BUCKET=kaxolax-templates` ; secrets `R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`. L'API lit le catalogue sur `TEMPLATES_BASE_URL` (posé par provision.sh).

## 6. Sauvegardes

Image et scripts : `scripts/backup/` de kaxolax-platform (le service `backup` est construit
depuis ce dépôt). Les sauvegardes sont chiffrées avec age : seule la clé publique est dans Railway.

- Clé, une fois, sur un poste d'opérateur : `age-keygen -o kaxolax-backup.key` ; garder ce fichier
  dans le gestionnaire de mots de passe (sans lui, aucune restauration possible) et passer la
  ligne `# public key: age1…` comme `AGE_RECIPIENT` à `railway/provision.sh`.
- Premier passage : Railway → service `backup` → « Run now », puis vérifier le journal
  (« sauvegarde envoyée ») et les objets `kaxolax-backups/postgres/<AAAAMMJJTHHMMSSZ>/`
  (`kaxolax.dump.age`, `manifest.txt`).
- **Test de restauration, chaque mois et après tout changement de version de PostgreSQL**, depuis
  un poste d'opérateur, dans un PostgreSQL jetable local (aucun accès à la production), depuis la
  racine de kaxolax-platform :

  ```sh
  docker build -f scripts/backup/Dockerfile -t kaxolax-pg-backup .
  docker run -d --name restore-db -e POSTGRES_PASSWORD=restore -p 127.0.0.1:55432:5432 postgres:18.6-alpine3.24
  terraform -chdir=../kaxolax-infra/cloudflare output -json railway_variables \
    | jq -r '.backup | to_entries[] | "\(.key)=\(.value)"' > /tmp/backup.env
  docker run --rm --network host --env-file /tmp/backup.env \
    -e RESTORE_ADMIN_URL=postgres://postgres:restore@127.0.0.1:55432/postgres \
    -e AGE_IDENTITY="$(grep '^AGE-SECRET-KEY-' kaxolax-backup.key)" \
    kaxolax-pg-backup /opt/kaxolax/backup/pg-restore-test.sh
  rm /tmp/backup.env; docker rm -f restore-db
  ```

  Le script vérifie la somme SHA-256, restaure dans une base temporaire, compare exactement les
  nombres de lignes des tables clés au manifeste et échoue si la sauvegarde a plus de 26 h. Il
  refuse une base égale à `DATABASE_URL`. Variante automatique : service `restore-test`
  (`deploy/railway/pg-restore-test.json`), seulement avec un PostgreSQL distinct de la production.
- Restauration réelle (incident) : arrêter api et realtime, déchiffrer
  (`age --decrypt -i kaxolax-backup.key -o kaxolax.dump kaxolax.dump.age`), restaurer dans une
  base neuve avec `pg_restore --no-owner --no-acl --dbname=<nouvelle base> kaxolax.dump`,
  vérifier, puis faire pointer les références `${{Postgres.*}}` des services vers la nouvelle
  base et redéployer.
- Test local de bout en bout (PostgreSQL et S3 de développement de kaxolax-platform, docker
  compose) : `scripts/backup/test-local.sh` dans kaxolax-platform (lancé aussi par sa CI).

## 7. Rotation

- Jeton R2 d'un service : `terraform -chdir=cloudflare apply -replace='cloudflare_account_token.r2["app"]'`
  (ou `backup`, `templates_publish`), puis `railway/provision.sh` (les variables S3 changées sont
  reposées) et redéploiement du service ; pour la galerie, mettre à jour les secrets GitHub.
- Secret applicatif généré (ex. `INTERNAL_TOKEN`) : `railway variable delete INTERNAL_TOKEN --service api`,
  `railway/provision.sh` (nouvelle valeur), redéployer api et realtime. Pour
  `COMPILE_WORKER_SECRET`, reposer aussi le secret du Worker.

## 8. Destruction

La zone et les buckets ont `prevent_destroy` : un `terraform destroy` échoue volontairement.
Pour retirer réellement la production, enlever ces protections dans une modification revue,
vider les buckets (le verrou des sauvegardes impose d'attendre son expiration), puis détruire.
