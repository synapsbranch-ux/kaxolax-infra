# Procédure de mise en production

Dans l'ordre. Rien n'est appliqué automatiquement : chaque étape est lancée par l'opérateur.
Commandes depuis la racine de ce dépôt, sauf mention contraire.

## 0. Prérequis

- Comptes : Cloudflare (Workers Paid pour Containers et Durable Objects), Railway (plan Pro
  conseillé), GitHub (dépôts kaxolax-platform, kaxolax-infra, kaxolax-templates), Clerk (instance
  de production), fournisseur SMTP.
- Domaine enregistré chez un registraire qui accepte DNSSEC.
- Outils : Terraform 1.16.4, CLI Railway ≥ 5.42, `jq`, `openssl`, `curl`, `docker`, `age` ; dans
  kaxolax-platform : `pnpm` (wrangler y est une dépendance).
- Une copie de kaxolax-platform à la révision déployée, à côté de ce dépôt
  (`../kaxolax-platform`, sinon `PLATFORM_DIR`) : `railway/provision.sh` lit ses
  `deploy/railway/*.json`, et le Worker se déploie depuis elle.

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

- `apps/compile-worker/wrangler.jsonc` : bindings R2 `PROJECT_FILES` et `COMPILE_OUTPUTS` (noms
  de `r2_buckets`, `jurisdiction: "eu"`), variable `OUTPUTS_BUCKET_NAME`, et le domaine de
  production à la place de `kaxolax.com` dans `routes` et `API_CALLBACK_URL`.
- Domaine `compile.<domaine>` déclaré comme domaine personnalisé du Worker (`custom_domain`) :
  wrangler crée l'enregistrement ; Terraform n'en gère pas sur ce nom.
- Les rappels du Worker (`https://api.<domaine>/api/v1/internal/compile-callbacks`) traversent
  la zone : ils sont exclus de la limitation de débit, et la règle WAF `/internal` ne vise que la
  racine des chemins (routes internes des services), pas `/api/v1/internal/`.
- Secret partagé avec l'API, posé après l'étape 4 :
  `railway variable list --service api --kv | grep '^COMPILE_WORKER_SECRET='` puis
  `pnpm --filter @kaxolax/compile-worker exec wrangler secret put COMPILE_WORKER_SECRET`.
- Image TeX Live épinglée, **avant le déploiement** : `docker buildx imagetools inspect
  ghcr.io/synapsbranch-ux/kaxolax-texlive:2026-medium` donne l'empreinte `sha256:…` de l'image
  publiée ; l'ajouter à `ARG TEXLIVE_IMAGE=…:2026-medium@sha256:…` de
  `apps/compile-worker/container/Dockerfile` (seule référence) et poser la même dans
  `texlive_digest` de `scripts/build.sh` de kaxolax-templates. Sans empreinte, la construction du
  conteneur par `wrangler deploy` échoue (`image_vars` de `wrangler.jsonc` passe
  `TEXLIVE_REQUIRE_PINNED=1`) : une étiquette peut désigner une autre image sans aucun commit.
- Déploiement : `pnpm --filter @kaxolax/compile-worker run deploy` (avec `run` : `pnpm deploy`
  seul est une commande intégrée de pnpm, qui copie un paquet du workspace et ne déploie rien),
  avec un jeton d'API
  **personnalisé, au moindre privilège** (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`),
  jamais le modèle « Edit Cloudflare Workers », qui donne aussi la gestion des buckets R2 et de
  KV sur tout le compte (un jeton volé pourrait retirer le verrou de `kaxolax-backups` puis tout
  effacer). Permissions : compte → « Workers Scripts : Edit », « Containers : Edit » (et
  « Account Settings : Read » si wrangler le demande) ; zone de production → « Workers Routes :
  Edit ». Ni « Workers R2 Storage » ni KV : déclarer un binding R2 n'exige pas de gérer les
  buckets, dont la création, le verrou et le cycle de vie restent à Terraform. Ce jeton n'est pas
  créé par Terraform (même règle que `docs/deploy.md` de kaxolax-platform).

## 4. Railway : projet, services, variables, domaines

1. Railway → Account → Tokens : jeton de **workspace** ; GitHub : installer l'application Railway
   sur kaxolax-platform (tous les services, sauvegarde comprise, sont construits depuis ce dépôt).
2. Le Dockerfile de kaxolax-platform choisit son étape finale avec l'argument de build
   `KAXOLAX_SERVICE` (web, admin, api, realtime), posé par le script comme variable de chaque
   service (Railway le transmet comme argument de build).
3. Lancer le provisionnement (d'abord à blanc) :

   ```sh
   export RAILWAY_API_TOKEN=… RAILWAY_WORKSPACE=… \
     PLATFORM_REPO=<owner>/kaxolax-platform PLATFORM_DIR=../kaxolax-platform \
     COMPILE_WORKER_URL=https://compile.<domaine>
   # Secrets fournis par l'opérateur (gestionnaire de mots de passe), jamais dans un fichier :
   export CLERK_PUBLISHABLE_KEY=… CLERK_SECRET_KEY=… CLERK_JWT_KEY=… CLERK_WEBHOOK_SIGNING_SECRET=… \
     ANTHROPIC_API_KEY=… \
     SMTP_HOST=… SMTP_PORT=465 SMTP_SECURE=true SMTP_USERNAME=… SMTP_PASSWORD=… \
     MAIL_FROM_ADDRESS=… MAIL_FROM_NAME=Kaxolax \
     AGE_RECIPIENT=age1…   # clé publique des sauvegardes (étape 6)
   railway/provision.sh --dry-run
   railway/provision.sh
   ```

   Le script crée ce qui manque (projet, PostgreSQL, Redis, services web, admin, api, realtime,
   backup) et pose les variables sans redéployer. Il déclare ensuite pour chaque service son
   fichier « config as code » (`/deploy/railway/<service>.json`, `pg-backup.json` pour backup :
   Settings → Config-as-code → Railway Config File, par l'API publique de Railway ; à poser à la
   main si le script l'annonce) et applique les sections `build` et `deploy` de ces fichiers
   (Dockerfile, `watchPatterns`, healthcheck et `healthcheckTimeout`, `drainingSeconds`,
   migrations en pré-déploiement de l'API, réplicas, cron de sauvegarde) : la CLI les applique
   par un commit d'environnement, qui redéploie les services concernés. Enfin il ajoute les
   domaines personnalisés (admin sur le port 3001, web 3000, api 3333, realtime 1234). Relancé,
   il ne recrée rien et garde les secrets générés (APP_KEY, REALTIME_TOKEN_SECRET,
   INTERNAL_TOKEN, COMPILE_WORKER_SECRET) ; une variable que l'API ne lit plus (`REDIS_URL`,
   `TEMPLATES_BASE_URL`) est signalée, jamais supprimée.
4. Reporter les cibles affichées (« enregistrements DNS demandés par Railway ») dans
   `cloudflare/terraform.tfvars` : CNAME dans `railway_targets`, TXT de vérification éventuels
   dans `extra_dns_records`. Puis `terraform -chdir=cloudflare apply`.
5. Attendre les certificats (`railway domain status <nom> --service <service>`), puis
   `ssl_mode = "strict"` et `terraform -chdir=cloudflare apply`.
6. Déployer : `railway redeploy --service <service>` pour chacun (ou un push sur `main`).

`SERVICES` restreint les services gérés (ex. `SERVICES="api" railway/provision.sh` pour reposer
les variables de l'API après une rotation). Les valeurs de construction et de déploiement ne se
changent que dans `deploy/railway/*.json` de kaxolax-platform (le cron de sauvegarde compris) :
Railway les relit à chaque déploiement.

## 5. Galerie de templates (`kaxolax-templates`) et index TeX Live (`kaxolax-texlive-index`)

Le bucket public `kaxolax-templates` (`templates.<domaine>`) porte la galerie, publiée à sa
racine par kaxolax-templates, son seul rédacteur. L'index des packages TeX Live, publié sous
`texlive/` par kaxolax-texlive-images, a son bucket **privé** `kaxolax-texlive-index` (ni
domaine public, ni expiration). L'API lit le catalogue par HTTPS (`TEMPLATES_CATALOG_URL`,
`https://templates.<domaine>/templates.json`, et `TEMPLATES_PUBLIC_URL`) et l'index par l'API S3
avec son jeton `app`, en lecture seule sur le bucket de l'index
(`TEXLIVE_INDEX_BUCKET=kaxolax-texlive-index`, `TEXLIVE_INDEX_KEY=texlive/2026/packages.json`) :
`provision.sh` pose ces quatre variables depuis les sorties Terraform.

```sh
terraform -chdir=cloudflare output r2_s3_endpoint templates_catalog_url texlive_index
terraform -chdir=cloudflare output -json r2_credentials | jq '.templates_publish'
terraform -chdir=cloudflare output -json r2_credentials | jq '.texlive_publish'
```

**kaxolax-templates** (Settings → Secrets and variables → Actions) :

- variables **du dépôt** (onglet « Variables », niveau dépôt et non environnement : la condition
  du job `publish` les lit avant d'entrer dans l'environnement) : `R2_BUCKET=kaxolax-templates`,
  `R2_ENDPOINT=https://<compte>.eu.r2.cloudflarestorage.com` (`r2_s3_endpoint`) ; `R2_PREFIX`
  vide (le catalogue doit rester à la racine, où l'API le lit) ;
- secrets de l'**environnement** `templates` (déploiement limité à `main`, règle posée avant les
  secrets) : `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` (jeton `templates_publish`).

**kaxolax-texlive-images** : environnement `r2-package-index` (limité à `main`) avec les
secrets `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` (jeton `texlive_publish`) et les variables
`R2_ENDPOINT` (`r2_s3_endpoint`) et `R2_PUBLIC_BUCKET=kaxolax-texlive-index`
(`texlive_index.bucket`) ; le workflow de ce dépôt ne change pas.

R2 ne restreint pas un jeton à un préfixe, d'où un bucket par rédacteur : `texlive_publish`
n'écrit que l'index. Sur le bucket de la galerie, il aurait pu réécrire `templates.json`, les zip
importés dans les projets (avec leur sha256, seule vérification de l'API) et le contenu servi sur
`templates.<domaine>`, sans revue. Les deux environnements GitHub restent limités à `main`.

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
    | jq -r '.restore_test | to_entries[] | "\(.key)=\(.value)"' > /tmp/backup.env
  docker run --rm --network host --env-file /tmp/backup.env \
    -e RESTORE_ADMIN_URL=postgres://postgres:restore@127.0.0.1:55432/postgres \
    -e AGE_IDENTITY="$(grep '^AGE-SECRET-KEY-' kaxolax-backup.key)" \
    kaxolax-pg-backup /opt/kaxolax/backup/pg-restore-test.sh
  rm /tmp/backup.env; docker rm -f restore-db
  ```

  Le script vérifie la somme SHA-256, restaure dans une base temporaire, compare exactement les
  nombres de lignes des tables clés au manifeste et échoue si la sauvegarde a plus de 26 h. Il
  refuse une base égale à `DATABASE_URL`. Variante automatique : service `restore-test`
  (`deploy/railway/pg-restore-test.json`), seulement avec un PostgreSQL distinct de la production,
  et avec les variables `restore_test` (jeton R2 `backup_read`, lecture seule), jamais le jeton
  `backup` : ce service détient la clé privée age.
- Restauration réelle (incident) : arrêter api et realtime, déchiffrer
  (`age --decrypt -i kaxolax-backup.key -o kaxolax.dump kaxolax.dump.age`), restaurer dans une
  base neuve avec `pg_restore --no-owner --no-acl --dbname=<nouvelle base> kaxolax.dump`,
  vérifier, puis faire pointer les références `${{Postgres.*}}` des services vers la nouvelle
  base et redéployer.
- Test local de bout en bout (PostgreSQL et S3 de développement de kaxolax-platform, docker
  compose) : `scripts/backup/test-local.sh` dans kaxolax-platform (lancé aussi par sa CI).

## 7. Rotation

- Jeton R2 d'un service : `terraform -chdir=cloudflare apply -replace='cloudflare_account_token.r2["app"]'`
  (ou `backup`, `backup_read`, `templates_publish`, `texlive_publish`), puis `railway/provision.sh`
  (les variables S3 changées sont reposées) et redéploiement du service ; pour la galerie et
  l'index TeX Live, mettre à jour les secrets GitHub de l'environnement concerné.
- Secret applicatif généré (ex. `INTERNAL_TOKEN`) : `railway variable delete INTERNAL_TOKEN --service api`,
  `railway/provision.sh` (nouvelle valeur), redéployer api et realtime. Pour
  `COMPILE_WORKER_SECRET`, reposer aussi le secret du Worker.

## 8. Destruction

La zone et les buckets ont `prevent_destroy` : un `terraform destroy` échoue volontairement.
Pour retirer réellement la production, enlever ces protections dans une modification revue,
vider les buckets (le verrou des sauvegardes impose d'attendre son expiration), puis détruire.
