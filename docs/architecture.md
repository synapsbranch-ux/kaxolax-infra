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
┌──────────────────────── Railway (réseau privé) ───┼──────────────────────────────────┐
│ web (Next.js) ──┐                                 ▼                                   │
│ admin (Next.js) ┼─▶ api (AdonisJS) ──▶ realtime (Hocuspocus) ── événements de build   │
│                 │        │                     │                                     │
│                 │        ├──▶ PostgreSQL ◀─────┘          backup (cron) ──▶ R2 backups │
│                 │        └──▶ Redis ◀──── realtime (extension Redis, plusieurs instances)│
└─────────────────────────────────────────────────────────────────────────────────────┘
```

## Réseau et sécurité

- **Tout passe par Cloudflare** : les quatre noms des services Railway sont des CNAME proxyfiés vers
  la cible `*.up.railway.app` de chaque domaine personnalisé. Railway route par l'en-tête Host.
- **TLS** : TLS 1.2 minimum, TLS 1.3, HTTPS forcé, HSTS six mois (sous-domaines compris, sans
  preload). Entre Cloudflare et Railway : mode `full` le temps de l'émission des certificats par
  Railway, puis `strict`. Le mode `flexible` (HTTP vers l'origine) est refusé par la validation.
- **WAF** (règles personnalisées, plan Free compris) : blocage public des routes `/internal/*`
  (le service temps réel ne les sert qu'au réseau privé), méthodes HTTP inconnues refusées sur
  l'API, seule la connexion WebSocket (GET) publique sur `realtime`, filtre par pays optionnel sur
  `admin`. Le « Cloudflare Free Managed Ruleset » s'applique d'office.
- **Limitation de débit** : 100 requêtes par 10 s et par IP sur `/api/*`, hors webhooks Clerk
  (`/api/v1/webhooks/*`) et rappels du Worker (`/api/v1/internal/*`). Le plan Pro permet une
  seconde règle (compilation).
- **Réseau privé de Railway** : web et admin appellent l'API par `api.railway.internal:3333`
  (réécriture `/api` de Next.js), l'API appelle realtime par `realtime.railway.internal:1234`.
  PostgreSQL et Redis n'ont pas de domaine public. Les services écoutent sur `::` (réseau privé
  IPv6 de Railway).
- **Accès administrateur** : Clerk (rôle `admin` et MFA, décision C.5) ; le filtre par pays de
  Cloudflare est une défense en profondeur.

## Stockage (R2)

| Bucket                    | Accès                                                   | Règles                                    |
| ------------------------- | ------------------------------------------------------- | ----------------------------------------- |
| `kaxolax-project-files`   | privé ; API (jeton `app`), Worker (binding)             | CORS app (GET, PUT), multipart purgé à 1 j |
| `kaxolax-compile-outputs` | privé ; Worker (binding, écriture), API (URL présignées) | CORS app (GET, Range), expiration optionnelle |
| `kaxolax-templates`       | public sur `templates.<domaine>` ; CI de kaxolax-templates | lecture seule pour le public, CORS app/admin |
| `kaxolax-backups`         | privé ; service `backup` (jeton `backup`)               | verrou 7 j, expiration 35 j               |

- Juridiction **UE** par défaut (données stockées dans l'Union européenne) ; endpoint S3
  `https://<compte>.eu.r2.cloudflarestorage.com`, avec le SDK S3 existant (`S3_REGION=auto`).
- URL `r2.dev` désactivées sur tous les buckets.
- **Jetons** : un jeton de compte par usage, groupe « Workers R2 Storage Bucket Item Write »
  limité aux buckets concernés (aucun droit de gestion des buckets ni de la zone). Restriction par
  IP possible (`token_allowed_cidrs`) avec les IP de sortie statiques de Railway.

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

Restent identiques : `latexmk -norc`, `texmf.cnf` durci (pas de shell escape, `openout_any = p`),
utilisateur non privilégié, limites de temps et de mémoire, processus tués après chaque
compilation. Le risque résiduel est qu'une compilation malveillante lise les fichiers temporaires
d'une compilation précédente **du même projet** pendant la session : acceptable, ces fichiers
appartiennent déjà aux membres du projet.

## Données et sauvegardes

- PostgreSQL de Railway (volume persistant). Service `backup` (image et scripts dans
  `scripts/backup/` de kaxolax-platform) : cron quotidien (03:17 UTC), `pg_dump` au format custom
  sur un instantané exporté, archive vérifiée (`pg_restore --list`), chiffrée avec age pour une clé
  publique, puis envoyée dans `kaxolax-backups` avec un manifeste (sha256, nombres de lignes des
  tables clés), sans jamais réécrire un objet. Rétention : 35 jours, au moins 7 sauvegardes.
- Le **verrou R2** interdit suppression et écrasement pendant 7 jours, même avec le jeton du
  service : un jeton volé ne peut pas effacer les sauvegardes récentes. La règle de cycle de vie
  supprime les sauvegardes après 35 jours (filet de sécurité de la rétention du script).
- `pg-restore-test.sh` restaure une sauvegarde dans une base temporaire, vérifie la somme et
  l'égalité exacte des nombres de lignes avec le manifeste, et échoue si la sauvegarde a plus de
  26 h. La clé privée age ne quitte pas le poste de l'opérateur (ou un service `restore-test`
  facultatif branché sur un PostgreSQL distinct).
- Redis ne contient que des données reconstructibles (présence, diffusion) : pas de sauvegarde.

## Ce qui n'est pas dans ce dépôt

- Code du Worker et du conteneur de compilation, `wrangler.jsonc` (bindings R2, domaine
  `compile.<domaine>`), Dockerfile des services : kaxolax-platform.
- Publication de la galerie : CI de kaxolax-templates (jeton `templates_publish`).
