# Architecture de production

Décision C.2 de l'étape 2 : Railway pour les services et les bases, Cloudflare pour le réseau, le
stockage et les compilations. Ce document décrit la cible ; la procédure de mise en place est dans
[procedure.md](procedure.md), les coûts dans [couts.md](couts.md).

## Vue d'ensemble

```
                         ┌───────────────────────── Cloudflare ─────────────────────────┐
navigateur ──HTTPS/WSS──▶│ DNS (DNSSEC) · CDN · WAF · limitation de débit · TLS 1.2+    │
                         │                                                               │
                         │  app / admin / api / realtime .<domaine> ──┐ (CNAME proxyfiés)│
                         │  templates.<domaine> ─▶ R2 kaxolax-templates (public)         │
                         │  compile.<domaine>   ─▶ Worker de compilation                 │
                         │                          │ binding R2 (fichiers, sorties)     │
                         │                          ▼                                    │
                         │                    Durable Object « projectId »               │
                         │                          │                                    │
                         │                    Container (VM isolée, sans réseau)         │
                         └──────────────────────────┼────────────────────────────────────┘
                                                    │ rappel signé (HMAC) → api
┌──────────────────────── Railway (réseau privé) ───┼───────────────────────────────────┐
│ web (Next.js) ──┐                                 ▼                                   │
│ admin (Next.js) ┼─▶ api (AdonisJS) ──▶ realtime ×2 (Hocuspocus) : événements de build │
│                 │        │                     │        │                             │
│                 │        └──▶ PostgreSQL ◀─────┘        └──▶ Redis (entre instances)  │
│                 │                      backup (cron) ──▶ R2 kaxolax-backups           │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

## Réseau et sécurité

- **Tout passe par Cloudflare** : les quatre noms des services Railway sont des CNAME proxyfiés vers
  la cible `*.up.railway.app` de chaque domaine personnalisé. Railway route par l'en-tête Host.
- **TLS** : TLS 1.2 minimum, TLS 1.3, HTTPS forcé, HSTS six mois (sous-domaines compris, sans
  preload). Entre Cloudflare et Railway : mode `full` le temps de l'émission des certificats par
  Railway, puis `strict`. Le mode `flexible` (HTTP vers l'origine) est refusé par la validation.
- **WAF** (règles personnalisées, plan Free compris) : blocage public des routes `/internal/*`,
  méthodes HTTP inconnues refusées sur l'API, seule la connexion WebSocket (GET) publique sur
  `realtime`, filtre par pays optionnel sur `admin`. Le « Cloudflare Free Managed Ruleset »
  s'applique d'office. Le service temps réel sert ses routes `/internal/*` sur son port public
  (le même que les WebSocket, derrière `realtime.<domaine>`) : elles sont protégées par cette
  règle WAF puis, à chaque requête, par le jeton interne (`X-Internal-Token`, secret
  `INTERNAL_TOKEN` partagé avec l'API ; 401 sans lui). L'API les appelle par le réseau privé.
- **Limitation de débit** : 100 requêtes par 10 s et par IP sur `/api/*`, hors webhooks Clerk
  (`/api/v1/webhooks/*`) et rappels du Worker (`/api/v1/internal/*`). Le plan Pro permet une
  seconde règle (compilation).
- **Origine non authentifiée** : Railway ne réserve pas ses domaines personnalisés à Cloudflare.
  Une connexion directe à l'edge de Railway (`curl --resolve api.<domaine>:443:<IP de l'edge>`)
  échappe au WAF et à la limitation de débit, et fait accepter des en-têtes `X-Forwarded-For`,
  `-Proto` et `-Host` choisis (`TRUSTED_PROXY_HOPS=2` de l'API ne les rend pas sûrs). Les routes
  sensibles ont leur propre protection (jetons Clerk, `X-Internal-Token`, HMAC des rappels) ;
  aucune règle ne repose sur l'IP. Si une règle doit un jour s'y fier : en-tête secret ajouté par
  une Transform Rule de Cloudflare (Terraform), vérifié par l'API, puis `CF-Connecting-IP` seul.
- **Réseau privé de Railway** : web et admin appellent l'API par `api.railway.internal:3333`
  (réécriture `/api` de Next.js), l'API appelle realtime par `realtime.railway.internal:1234`.
  PostgreSQL et Redis n'ont pas de domaine public ; Redis ne sert qu'aux deux instances de
  realtime (extension Redis de Hocuspocus, bus entre instances), l'API ne l'utilise pas. Les
  services écoutent sur `::` (réseau privé IPv6 de Railway) ; ports : web 3000, admin 3001,
  api 3333, realtime 1234.
- **Accès administrateur** : Clerk (rôle `admin` et MFA, décision C.5) ; le filtre par pays de
  Cloudflare est une défense en profondeur.

## Stockage (R2)

| Bucket                    | Accès                                                   | Règles                                    |
| ------------------------- | ------------------------------------------------------- | ----------------------------------------- |
| `kaxolax-project-files`   | privé ; API (jeton `app`), Worker (binding)             | CORS app (GET, PUT), `uploads/` expirés à 1 j, multipart purgé à 1 j |
| `kaxolax-compile-outputs` | privé ; Worker (binding, écriture), API (jeton `app`, URL présignées) | CORS app (GET, Range), expiration à 7 j |
| `kaxolax-templates`       | public sur `templates.<domaine>` ; seul rédacteur : CI de kaxolax-templates (jeton `templates_publish`) ; API par HTTPS | lecture seule pour le public, CORS app/admin (GET, Range) |
| `kaxolax-texlive-index`   | privé ; CI de kaxolax-texlive-images (jeton `texlive_publish`, `texlive/`), API (jeton `app`, lecture) | ni domaine public ni expiration |
| `kaxolax-backups`         | privé ; service `backup` (jeton `backup`), test de restauration (jeton `backup_read`, lecture) | verrou 7 j, expiration 45 j |

- Juridiction **UE** par défaut (données stockées dans l'Union européenne) ; endpoint S3
  `https://<compte>.eu.r2.cloudflarestorage.com`, avec le SDK S3 existant (`S3_REGION=auto`).
- URL `r2.dev` désactivées sur tous les buckets.
- **Confidentialité** : les sorties de compilation (PDF, journaux, et les demandes, qui
  contiennent les sources) expirent après 7 jours (`compile_outputs_retention_days`), les
  téléversements jamais confirmés après 1 jour (`pending_uploads_retention_days`), comme en
  local. La suppression définitive d'un projet efface aussi `projects/<id>/` et
  `outputs/<id>/` (API).
- **Jetons** : un jeton de compte par usage, groupe « Workers R2 Storage Bucket Item Write »
  (ou « Item Read ») limité aux buckets concernés, aucun droit de gestion des buckets ni de la
  zone : `app` (écriture sur les fichiers et les sorties, lecture sur l'index TeX Live),
  `backup`, `backup_read` (lecture), `templates_publish` (galerie), `texlive_publish` (index).
  R2 ne restreint pas un jeton à un préfixe : un bucket par rédacteur, pour que seule la CI de
  kaxolax-templates puisse écrire la galerie publique (catalogue, zip importés, contenu de
  `templates.<domaine>`).
  Restriction par IP possible (`token_allowed_cidrs`) avec les IP de sortie statiques de Railway.

## Compilation asynchrone

1. Le navigateur demande une compilation à l'API (`POST /projects/:id/compile`) ; avec
   `COMPILE_BACKEND=cloudflare`, l'API enregistre la demande et répond tout de suite un `buildId`.
2. L'API appelle le Worker (`COMPILE_WORKER_URL`, jeton signé avec `COMPILE_WORKER_SECRET`). Le
   Worker adresse le Durable Object du projet (`idFromName(projectId)`), qui démarre ou réveille
   son conteneur ; pendant le réveil la demande est mise en file (« Préparation du compilateur… »).
   À l'ouverture de l'éditeur, l'API réveille le conteneur par anticipation
   (`POST /projects/:id/compiler/warm`).
3. Le Worker lit les fichiers du projet par son binding R2 et les passe au conteneur, qui n'a ni
   réseau (`enableInternet = false`) ni identifiants. Les sorties (PDF, journal, SyncTeX) sont
   écrites par le Worker dans `kaxolax-compile-outputs`.
4. Le Worker rappelle l'API (`POST /api/v1/internal/compile-callbacks`, corps signé HMAC) ; l'API
   met à jour la table `compiles` et publie l'événement au service temps réel, qui le pousse aux
   navigateurs du projet. Pas de requête HTTP longue : Cloudflare coupe à 100 s, une compilation
   Pro dure jusqu'à 4 min.
5. Le conteneur se met en veille ~15 min après la dernière activité.

`COMPILE_BACKEND=gateway` (défaut en local et en CI) garde la compilation synchrone de l'étape 1
(compile-gateway, Docker + gVisor).

### Écart au sandbox de l'étape 1

| Étape 1 (gVisor)                                 | Production (Cloudflare Containers)                          |
| ------------------------------------------------ | ----------------------------------------------------------- |
| conteneur Docker neuf par compilation, `runsc`   | VM isolée par session de projet (un Durable Object par projet) |
| aucun réseau (`--network none`)                  | aucun réseau (`enableInternet = false`)                     |
| fichiers montés depuis le worker                 | fichiers passés par le Worker (binding R2), pas d'identifiants dans la VM |

Gardé : `latexmk -norc`, `texmf.cnf` durci (pas de shell escape, `openout_any = p`), utilisateur
non privilégié (UID 1000, `setpriv`), `prlimit` (taille de fichier, nombre de processus), délai
maximal par compilation, processus tués et `/tmp` vidé après chaque compilation.

Perdu par rapport à l'étape 1 (écart à valider avant la mise en production, voir
`docs/decisions.md` de kaxolax-platform) :

- **limites mémoire et CPU par compilation** : plus de cgroup par conteneur ; seules celles de la
  VM du projet s'appliquent (`instance_type`), et `oom_score_adj` protège l'agent ;
- **isolation entre deux compilations d'un même projet** : la VM est réutilisée pendant la
  session ; une compilation malveillante peut lire les fichiers temporaires d'une compilation
  précédente du même projet, qui appartiennent déjà à ses membres.

## Données et sauvegardes

- PostgreSQL de Railway (volume persistant). Service `backup` (image et scripts dans
  `scripts/backup/` de kaxolax-platform) : cron quotidien (03:17 UTC), `pg_dump` au format custom
  sur un instantané exporté, archive vérifiée (`pg_restore --list`), chiffrée avec age pour une clé
  publique, puis envoyée dans `kaxolax-backups` avec un manifeste (sha256, nombres de lignes des
  tables clés), sans jamais réécrire un objet. Rétention : 35 jours, au moins 7 sauvegardes.
- Le **verrou R2** interdit suppression et écrasement pendant 7 jours, même avec le jeton du
  service : un jeton volé ne peut pas effacer les sauvegardes récentes. La règle de cycle de vie
  supprime les sauvegardes après 45 jours : filet de sécurité au-delà de la rétention du script
  (35 jours, au moins les 7 plus récentes). Si le job s'arrête, cette règle finit par tout
  effacer : la surveillance du job de sauvegarde (alerte sur échec ou absence) est indispensable.
- `pg-restore-test.sh` restaure une sauvegarde dans une base temporaire, vérifie la somme et
  l'égalité exacte des nombres de lignes avec le manifeste, et échoue si la sauvegarde a plus de
  26 h. La clé privée age ne quitte pas le poste de l'opérateur (ou un service `restore-test`
  facultatif branché sur un PostgreSQL distinct).
- Redis ne contient que des données reconstructibles (présence, diffusion) : pas de sauvegarde.

## Ce qui n'est pas dans ce dépôt

- Code du Worker et du conteneur de compilation, `wrangler.jsonc` (bindings R2, domaine
  `compile.<domaine>`), Dockerfile des services : kaxolax-platform.
- Publication de la galerie : CI de kaxolax-templates (jeton `templates_publish`) ; index des
  packages TeX Live : CI de kaxolax-texlive-images (jeton `texlive_publish`).
