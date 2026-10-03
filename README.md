# kaxolax-infra

Infrastructure de production de Kaxolax (étape 2, décision C.2) : **Cloudflare** (DNS, CDN, WAF,
R2, Worker et Containers de compilation) et **Railway** (web, admin, api, realtime, PostgreSQL,
Redis, sauvegardes). AWS n'est plus utilisé ; le staging AWS de l'étape 1 est archivé dans
[`legacy/aws-step1/`](legacy/aws-step1/README.md).

```
cloudflare/         Terraform (fournisseur officiel cloudflare/cloudflare 5.26.0)
  main.tf           zone, DNSSEC, réglages TLS et HSTS
  dns.tf            CNAME proxyfiés vers Railway, enregistrements supplémentaires (TXT, MX)
  security.tf       règles WAF de base, limitation de débit de l'API
  r2.tf             buckets R2, domaine public de la galerie, CORS, cycle de vie, verrou
  tokens.tf         jetons R2 au moindre privilège (un par usage)
  tests/            terraform test avec un fournisseur simulé, sans compte Cloudflare
railway/
  provision.sh      provisionnement idempotent du projet Railway (CLI officielle)
docs/               architecture, coûts, procédure de mise en production, décisions
legacy/aws-step1/   Terraform AWS du staging de l'étape 1 (archivé, plus appliqué)
```

## Architecture

```
navigateur ──HTTPS──▶ Cloudflare (DNS, CDN, WAF, limitation de débit)
                        │
                        ├─ app.<domaine>       ─▶ Railway web (Next.js)
                        ├─ admin.<domaine>     ─▶ Railway admin (Next.js)
                        ├─ api.<domaine>       ─▶ Railway api (AdonisJS)
                        ├─ realtime.<domaine>  ─▶ Railway realtime (Hocuspocus, WebSocket)
                        ├─ templates.<domaine> ─▶ R2 kaxolax-templates (public, lecture seule)
                        └─ compile.<domaine>   ─▶ Worker de compilation (déployé par wrangler)
                                                    └─ Durable Object par projet ─▶ Container
                                                       (VM isolée, sans réseau, veille ~15 min)

Railway (réseau privé *.railway.internal) : web/admin → api → realtime (2 instances reliées par
Redis), PostgreSQL, backup (cron quotidien : pg_dump → R2 kaxolax-backups)

R2 (juridiction UE) : kaxolax-project-files, kaxolax-compile-outputs (privés, URL présignées ;
uploads en attente expirés à 1 j, sorties à 7 j), kaxolax-templates (public : galerie),
kaxolax-texlive-index (privé : index des packages TeX Live), kaxolax-backups (privé, verrou 7 j,
rétention 35 j par le job, expiration 45 j)
```

Détails, flux de compilation asynchrone et écarts au sandbox de l'étape 1 :
[docs/architecture.md](docs/architecture.md). Coûts : [docs/couts.md](docs/couts.md).

## Ce qui est géré où

| Élément                                         | Outil                                                 |
| ----------------------------------------------- | ----------------------------------------------------- |
| Zone, DNS, TLS, WAF, limitation de débit        | Terraform `cloudflare/`                               |
| Buckets R2, CORS, cycle de vie, verrou, jetons  | Terraform `cloudflare/`                               |
| Domaine public de la galerie                    | Terraform `cloudflare/` (`cloudflare_r2_custom_domain`) |
| Worker et Containers de compilation, son domaine | `wrangler deploy` depuis kaxolax-platform             |
| Projet, services, variables, domaines Railway   | `railway/provision.sh` (CLI Railway), valeurs de `deploy/railway/*.json` de kaxolax-platform |
| Sauvegardes PostgreSQL                          | service `backup` de Railway (`scripts/backup/` de kaxolax-platform) |

Railway n'a pas de fournisseur Terraform officiel ; le fournisseur communautaire et l'IaC
TypeScript de Railway (bêta) sont écartés pour l'instant (voir [docs/decisions.md](docs/decisions.md)).

## Mise en production

Procédure complète, dans l'ordre : [docs/procedure.md](docs/procedure.md). En résumé :

1. Bucket R2 d'état et jeton de Terraform (tableau de bord Cloudflare, une fois).
2. `terraform -chdir=cloudflare apply` : zone, buckets, jetons ; serveurs de noms et DS chez le
   registraire.
3. Empreinte de l'image TeX Live posée dans `TEXLIVE_IMAGE` (`…:2026-medium@sha256:…`) de
   `apps/compile-worker/container/Dockerfile` (sinon le build échoue), puis
   `pnpm --filter @kaxolax/compile-worker run deploy` (kaxolax-platform), avec les buckets en
   sortie.
4. `railway/provision.sh` : projet, bases, services, variables, domaines ; cibles CNAME reportées
   dans `cloudflare/terraform.tfvars`, puis nouvel `apply`.
5. Certificats émis par Railway : `ssl_mode = "strict"`, `apply`.
6. Variables des CI de kaxolax-templates (jeton `templates_publish`) et de
   kaxolax-texlive-images (jeton `texlive_publish`, bucket privé `kaxolax-texlive-index`).

## Vérifications

```sh
terraform fmt -check -recursive
terraform -chdir=cloudflare init -backend=false && terraform -chdir=cloudflare validate
terraform -chdir=cloudflare test          # fournisseur simulé, sans compte Cloudflare
shellcheck -x railway/*.sh
```

Test local des sauvegardes (PostgreSQL et S3 de développement de kaxolax-platform) : voir
« Sauvegardes » dans [docs/procedure.md](docs/procedure.md).

## Secrets

Aucun secret dans ce dépôt. Jeton d'API de Terraform : `CLOUDFLARE_API_TOKEN` ; état : bucket R2
privé (`backend.hcl` non versionné). Les jetons R2 créés par Terraform sont dans l'état et en
sorties sensibles ; `provision.sh` les passe à Railway par l'entrée standard de la CLI. Les secrets
applicatifs (APP_KEY, jetons internes) sont générés une fois dans Railway et n'en sortent pas.

## Limites connues

- Pas d'environnement de staging (décision C.1) ; `terraform test` et `--dry-run` tiennent lieu de
  contrôle avant application.
- Railway ne sélectionne pas de cible de build : la dernière étape de `docker/Dockerfile` de
  kaxolax-platform reprend celle que désigne l'argument `KAXOLAX_SERVICE` (variable posée par
  `provision.sh` : web, admin, api ou realtime ; sans elle, le build échoue avec un message
  explicite).
- Le chemin du fichier de configuration de chaque service (« Railway Config File ») se pose par
  l'API GraphQL publique de Railway, que la CLI n'expose pas : en cas d'échec, le script le
  signale et le chemin se pose à la main (procédure, §4).
- R2 ne restreint pas un jeton à un préfixe : un bucket par rédacteur. `templates_publish` est
  le seul à écrire la galerie publique, `texlive_publish` n'écrit que l'index privé ; les
  environnements GitHub limités à `main` protègent leurs secrets.
- Plan Free de Cloudflare : une seule règle de limitation de débit, expression sur le chemin
  seulement, pas de Managed Ruleset complet. Le plan Pro lève ces limites (variable `rate_limits`).
- Le test de restauration est lancé à la main (ou par un cron ajouté à la main) : il faut une base
  jetable distincte de la production.
