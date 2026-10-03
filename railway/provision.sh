#!/usr/bin/env bash
# Provisionnement idempotent du projet Railway de production avec la CLI officielle.
#
# Crée ce qui manque (projet, PostgreSQL, Redis, services web, admin, api, realtime, backup),
# applique la configuration de construction et de déploiement lue dans deploy/railway/*.json de
# kaxolax-platform (Dockerfile, watchPatterns, healthcheck, migrations, réplicas, cron) et déclare
# ce fichier comme « Railway Config File » de chaque service, pose les variables et ajoute les
# domaines personnalisés. Relancé, il ne recrée rien, ne régénère aucun secret existant et ne
# supprime rien. Voir docs/procedure.md.
#
#   railway/provision.sh [--dry-run]
#
# Prérequis : CLI Railway >= 5.42 (sorties --json), jq, openssl, curl, terraform (sorties de
# cloudflare/), et une copie de kaxolax-platform à la révision déployée (PLATFORM_DIR).
# Authentification : RAILWAY_API_TOKEN (jeton de workspace), jamais écrit sur le disque.
#
# Entrées (variables d'environnement) :
#   RAILWAY_WORKSPACE      nom ou identifiant du workspace Railway (obligatoire)
#   RAILWAY_PROJECT        nom du projet (kaxolax)
#   RAILWAY_ENVIRONMENT    environnement (production)
#   PLATFORM_REPO          dépôt GitHub de la plateforme, owner/kaxolax-platform (obligatoire)
#   PLATFORM_DIR           copie locale de kaxolax-platform (../kaxolax-platform à côté de ce dépôt)
#   DEPLOY_BRANCH          branche déployée (main)
#   COMPILE_WORKER_URL     URL du Worker de compilation Cloudflare (obligatoire)
#   SERVICES               services applicatifs à gérer (« web admin api realtime backup »)
# Valeurs transmises telles quelles si elles sont définies (secrets fournis par l'opérateur) :
#   CLERK_PUBLISHABLE_KEY CLERK_SECRET_KEY CLERK_JWT_KEY CLERK_WEBHOOK_SIGNING_SECRET
#   ANTHROPIC_API_KEY (assistant IA de l'api ; sans elle, les routes IA répondent 503)
#   SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_SECURE MAIL_FROM_ADDRESS MAIL_FROM_NAME
#   (port 465 : SMTP_SECURE=true, sinon avertissement)
#   AGE_RECIPIENT (clé publique age des sauvegardes ; la clé privée reste hors de Railway)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TF_DIR="${SCRIPT_DIR}/../cloudflare"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--dry-run]" >&2
  exit 2
fi

RAILWAY_PROJECT="${RAILWAY_PROJECT:-kaxolax}"
RAILWAY_ENVIRONMENT="${RAILWAY_ENVIRONMENT:-production}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
PLATFORM_DIR="${PLATFORM_DIR:-${SCRIPT_DIR}/../../kaxolax-platform}"
SERVICES="${SERVICES:-web admin api realtime backup}"

# API publique de Railway (GraphQL) : chemin du fichier de configuration d'un service, que la CLI
# ne sait pas poser.
readonly RAILWAY_GRAPHQL_URL="${RAILWAY_GRAPHQL_URL:-https://backboard.railway.com/graphql/v2}"

# Noms des bases dans Railway (noms par défaut des modèles PostgreSQL et Redis).
readonly PG_SERVICE="Postgres"
readonly REDIS_SERVICE="Redis"

# Variables transmises depuis l'environnement de l'opérateur, par service.
readonly PASSTHROUGH_API="CLERK_JWT_KEY CLERK_SECRET_KEY CLERK_WEBHOOK_SIGNING_SECRET ANTHROPIC_API_KEY SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_SECURE MAIL_FROM_ADDRESS MAIL_FROM_NAME"
readonly PASSTHROUGH_WEB="CLERK_PUBLISHABLE_KEY CLERK_SECRET_KEY CLERK_JWT_KEY"
# Variables sans lesquelles l'API ne démarre pas (start/env.ts).
readonly REQUIRED_API="CLERK_JWT_KEY SMTP_HOST SMTP_PORT MAIL_FROM_ADDRESS MAIL_FROM_NAME"
# Variables que l'API ne lit plus : signalées si elles restent (le script ne supprime rien).
readonly OBSOLETE_API="REDIS_URL TEMPLATES_BASE_URL"

log() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf 'ATTENTION : %s\n' "$*" >&2; }
die() {
  printf 'ERREUR : %s\n' "$*" >&2
  exit 1
}

# Commande qui modifie Railway : affichée seulement en --dry-run.
mutate() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '[dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

require_tools() {
  local tool
  for tool in railway jq openssl curl terraform; do
    command -v "$tool" >/dev/null || die "outil manquant : $tool"
  done
  local version
  version="$(railway --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
  [[ -n "$version" ]] || die "version de la CLI Railway illisible"
  if [[ "$(printf '%s\n5.42.0\n' "$version" | sort -V | head -n 1)" != "5.42.0" ]]; then
    die "CLI Railway $version trop ancienne (5.42.0 au minimum)"
  fi
  [[ -n "${RAILWAY_API_TOKEN:-}" ]] || die "RAILWAY_API_TOKEN manquant (jeton de workspace Railway)"
  local name
  for name in RAILWAY_WORKSPACE PLATFORM_REPO COMPILE_WORKER_URL; do
    [[ -n "${!name:-}" ]] || die "variable $name manquante"
  done
  [[ "$COMPILE_WORKER_URL" == https://* ]] || die "COMPILE_WORKER_URL doit être une URL https://"
  [[ -d "${PLATFORM_DIR}/deploy/railway" ]] ||
    die "PLATFORM_DIR=${PLATFORM_DIR} : copie de kaxolax-platform introuvable (deploy/railway/ absent)"
}

# Sorties Terraform de cloudflare/ (domaines, variables R2). Les valeurs sensibles ne sont jamais
# affichées ni passées en argument d'une commande (visibles dans `ps` et /proc/<pid>/cmdline) :
# elles circulent par l'entrée standard, les tubes ou l'environnement de jq.
load_terraform_outputs() {
  TF_OUTPUTS="$(terraform -chdir="$TF_DIR" output -json)" || die "terraform output a échoué dans cloudflare/"
  HOST_APP="$(jq -r '.hostnames.value.app' <<<"$TF_OUTPUTS")"
  HOST_ADMIN="$(jq -r '.hostnames.value.admin' <<<"$TF_OUTPUTS")"
  HOST_API="$(jq -r '.hostnames.value.api' <<<"$TF_OUTPUTS")"
  HOST_REALTIME="$(jq -r '.hostnames.value.realtime' <<<"$TF_OUTPUTS")"
  [[ "$HOST_APP" != null && -n "$HOST_APP" ]] || die "sortie hostnames absente : appliquer cloudflare/ d'abord"
  [[ "$(jq -r '.railway_variables.value.api | has("TEXLIVE_INDEX_BUCKET")' <<<"$TF_OUTPUTS")" == true ]] ||
    die "sorties Terraform périmées (TEXLIVE_INDEX_BUCKET absent) : terraform -chdir=cloudflare apply"
}

# Objet JSON des variables R2 d'un service, écrit sur la sortie standard.
tf_railway_variables() {
  jq -c --arg service "$1" '.railway_variables.value[$service]' <<<"$TF_OUTPUTS"
}

# Fusionne les objets JSON lus sur l'entrée standard (le dernier l'emporte).
merge_objects() {
  jq -cs 'add // {}'
}

# --- Projet et environnement -------------------------------------------------------------------

link_project() {
  local project_id
  project_id="$(railway list --json | jq -r --arg name "$RAILWAY_PROJECT" --arg ws "$RAILWAY_WORKSPACE" \
    '[.[] | select(.name == $name and (.workspace.name == $ws or .workspace.id == $ws)) | .id] | if length > 1 then error("several projects named \($name)") else (.[0] // "") end')"
  if [[ -z "$project_id" ]]; then
    log "création du projet $RAILWAY_PROJECT"
    if [[ "$DRY_RUN" == 1 ]]; then
      mutate railway init --name "$RAILWAY_PROJECT" --workspace "$RAILWAY_WORKSPACE" --json
      log "dry-run : projet absent, la suite n'est pas simulée"
      exit 0
    fi
    project_id="$(railway init --name "$RAILWAY_PROJECT" --workspace "$RAILWAY_WORKSPACE" --json | jq -r '.id')"
  fi
  # Le lien est écrit dans la configuration locale de la CLI (~/.railway), pas dans ce dépôt.
  railway link --project "$project_id" --environment "$RAILWAY_ENVIRONMENT" --json >/dev/null \
    || die "environnement $RAILWAY_ENVIRONMENT introuvable dans le projet (railway environment new $RAILWAY_ENVIRONMENT)"
  PROJECT_ID="$project_id"
  log "projet $RAILWAY_PROJECT ($PROJECT_ID), environnement $RAILWAY_ENVIRONMENT"
}

refresh_status() {
  STATUS="$(railway status --json)"
}

# Identifiant de l'environnement lié (vide s'il est introuvable dans la sortie de la CLI).
environment_id() {
  jq -r --arg env "$RAILWAY_ENVIRONMENT" \
    '[(.environments.edges // [])[].node | select(.name == $env) | .id][0] // ""' <<<"$STATUS"
}

service_id() {
  jq -r --arg name "$1" '[.services.edges[].node | select(.name == $name) | .id][0] // ""' <<<"$STATUS"
}

ensure_database() {
  local name="$1" kind="$2"
  if [[ -z "$(service_id "$name")" ]]; then
    log "ajout de la base $kind ($name)"
    mutate railway add --database "$kind" --json >/dev/null
  fi
}

ensure_service() {
  local name="$1" repo="$2"
  if [[ -z "$(service_id "$name")" ]]; then
    log "création du service $name ($repo@$DEPLOY_BRANCH)"
    mutate railway add --service "$name" --repo "$repo" --branch "$DEPLOY_BRANCH" --json >/dev/null
  fi
}

# --- Configuration de construction et de déploiement ------------------------------------------

# Fichier « config as code » de chaque service dans kaxolax-platform (chemin depuis la racine du
# dépôt, tel que Railway l'attend dans Settings → Config-as-code → Railway Config File).
config_file() {
  case "$1" in
    web | admin | api | realtime) printf '/deploy/railway/%s.json' "$1" ;;
    backup) printf '/deploy/railway/pg-backup.json' ;;
    *) die "service inconnu : $1" ;;
  esac
}

# Configuration d'un service pour le patch d'environnement (railway environment edit) : les
# sections build et deploy de son fichier, seule source des valeurs (Dockerfile, watchPatterns,
# healthcheck et son délai, drainingSeconds, migrations, réplicas par région, cron). Railway ne
# sélectionne pas de cible de build : KAXOLAX_SERVICE (variable de service, transmise comme
# argument de build) choisit l'étape finale du Dockerfile de la plateforme.
service_config() {
  local file
  file="${PLATFORM_DIR}$(config_file "$1")"
  [[ -f "$file" ]] || die "configuration absente : $file"
  jq -c '{build, deploy}
    | if .deploy.preDeployCommand | type == "string" then .deploy.preDeployCommand |= [.] else . end' "$file" ||
    die "configuration illisible : $file"
}

# La CLI applique le patch par un commit d'environnement, qui redéploie les services modifiés.
apply_service_configs() {
  local patch='{"services":{}}' name id
  for name in $SERVICES; do
    id="$(service_id "$name")"
    [[ -n "$id" ]] || continue
    patch="$(jq --arg id "$id" --argjson cfg "$(service_config "$name")" '.services[$id] = $cfg' <<<"$patch")"
  done
  log "configuration de construction et de déploiement (deploy/railway/*.json)"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '[dry-run] railway environment edit <<< %s\n' "$patch" >&2
  else
    railway environment edit --environment "$RAILWAY_ENVIRONMENT" <<<"$patch" >/dev/null
  fi
}

# Déclare le fichier de configuration du service (serviceInstanceUpdate de l'API publique) : Railway
# le relit à chaque déploiement, et ses valeurs priment sur celles du tableau de bord. En cas
# d'échec, le patch d'environnement reste appliqué et l'opérateur pose le chemin à la main. Le
# jeton passe par un descripteur (en-tête lu par curl), jamais dans la ligne de commande.
set_config_file() {
  local name="$1" id="$2" env_id="$3" path body
  path="$(config_file "$name")"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '[dry-run] %s : Railway Config File = %s\n' "$name" "$path" >&2
    return
  fi
  body="$(jq -cn --arg service "$id" --arg env "$env_id" --arg path "$path" '{
    query: "mutation($serviceId: String!, $environmentId: String, $input: ServiceInstanceUpdateInput!) { serviceInstanceUpdate(serviceId: $serviceId, environmentId: $environmentId, input: $input) }",
    variables: {serviceId: $service, environmentId: $env, input: {railwayConfigFile: $path}}
  }')"
  if curl -fsS --max-time 30 "$RAILWAY_GRAPHQL_URL" \
    -H 'Content-Type: application/json' \
    -H @<(printf 'Authorization: Bearer %s\n' "$RAILWAY_API_TOKEN") \
    --data-binary "$body" | jq -e '(.errors // []) | length == 0' >/dev/null; then
    log "$name : Railway Config File = $path"
  else
    warn "$name : Railway Config File non posé ; Settings → Config-as-code → $path"
  fi
}

apply_config_files() {
  local env_id name id
  env_id="$(environment_id)"
  if [[ -z "$env_id" && "$DRY_RUN" == 0 ]]; then
    warn "identifiant de l'environnement $RAILWAY_ENVIRONMENT introuvable : poser les Railway Config File à la main (docs/procedure.md)"
    return
  fi
  for name in $SERVICES; do
    id="$(service_id "$name")"
    [[ -n "$id" ]] || continue
    set_config_file "$name" "$id" "$env_id"
  done
}

# --- Variables ----------------------------------------------------------------------------------

existing_variables() {
  railway variable list --service "$1" --environment "$RAILWAY_ENVIRONMENT" --json
}

# Pose une variable sans déclencher de déploiement ; la valeur passe par l'entrée standard (jamais
# dans la ligne de commande ni dans les journaux).
set_variable() {
  local service="$1" key="$2" value="$3"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '[dry-run] %s : %s\n' "$service" "$key" >&2
    return
  fi
  printf '%s' "$value" | railway variable set "$key" --stdin --service "$service" \
    --environment "$RAILWAY_ENVIRONMENT" --skip-deploys --json >/dev/null
}

# Pose un ensemble clé → valeur (objet JSON) ; les valeurs identiques sont ignorées.
set_variables() {
  local service="$1" wanted="$2" current key value
  current="$(existing_variables "$service")"
  while IFS= read -r key; do
    value="$(jq -r --arg k "$key" '.[$k]' <<<"$wanted")"
    if [[ "$(jq -r --arg k "$key" '.[$k] // empty' <<<"$current")" != "$value" ]]; then
      set_variable "$service" "$key" "$value"
    fi
  done < <(jq -r 'keys[]' <<<"$wanted")
}

# Secret généré une seule fois : conservé s'il existe déjà (rotation : docs/procedure.md).
ensure_secret() {
  local service="$1" key="$2"
  if [[ "$(existing_variables "$service" | jq -r --arg k "$key" 'has($k)')" != "true" ]]; then
    log "génération de $key ($service)"
    set_variable "$service" "$key" "$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c 1-48)"
  fi
}

# Objet JSON des variables de l'opérateur (liste de noms en argument) définies et non vides. Les
# valeurs sont lues par jq dans son environnement (`export` est une commande interne de bash) :
# seuls les noms apparaissent dans sa ligne de commande.
passthrough() {
  local key
  for key in $1; do
    if [[ -n "${!key:-}" ]]; then
      export "${key?}"
    fi
  done
  jq -cn --arg keys "$1" \
    '[$keys | splits(" +") | select(length > 0) | select((env[.] // "") != "") | {(.): env[.]}] | add // {}'
}

# SMTP_PORT et SMTP_SECURE de l'api (valeur passée au script, sinon celle déjà posée ; JSON des
# variables existantes en argument). Le port 465 attend TLS dès la connexion, que nodemailer
# n'ouvre qu'avec SMTP_SECURE=true : sans lui, chaque envoi reste bloqué jusqu'au délai d'attente
# (emails d'invitation et de mention perdus). À l'inverse, 587 et 25 commencent en clair (STARTTLS).
check_smtp_tls() {
  local port secure
  port="${SMTP_PORT:-$(jq -r '.SMTP_PORT // empty' <<<"$1")}"
  secure="${SMTP_SECURE:-$(jq -r '.SMTP_SECURE // empty' <<<"$1")}"
  if [[ "$port" == 465 && "$secure" != true && "$secure" != 1 ]]; then
    warn "api : SMTP_PORT=465 sans SMTP_SECURE=true (TLS implicite non activé : les emails ne partiront pas)"
  elif [[ ("$port" == 587 || "$port" == 25) && ("$secure" == true || "$secure" == 1) ]]; then
    warn "api : SMTP_SECURE=true sur le port $port (STARTTLS) : utiliser 465, ou retirer SMTP_SECURE"
  fi
}

configure_variables() {
  local name
  for name in $SERVICES; do
    [[ -n "$(service_id "$name")" ]] || continue
    log "variables de $name"
    case "$name" in
      api)
        ensure_secret api APP_KEY
        ensure_secret api REALTIME_TOKEN_SECRET
        ensure_secret api INTERNAL_TOKEN
        ensure_secret api COMPILE_WORKER_SECRET
        # Valeurs sensibles (R2, opérateur) fusionnées par un tube, jamais en argument. Terraform
        # fournit aussi la galerie (TEMPLATES_*) et l'index TeX Live (TEXLIVE_INDEX_*).
        set_variables api "$({
          jq -n \
            --arg app "https://$HOST_APP" --arg admin "https://$HOST_ADMIN" \
            --arg rt "wss://$HOST_REALTIME" --arg worker "$COMPILE_WORKER_URL" \
            '{
            KAXOLAX_SERVICE: "api", NODE_ENV: "production", LOG_LEVEL: "info",
            HOST: "::", PORT: "3333", APP_URL: $app, ADMIN_URL: $admin,
            TRUSTED_PROXY_HOPS: "2",
            DB_HOST: "${{Postgres.PGHOST}}", DB_PORT: "${{Postgres.PGPORT}}",
            DB_USER: "${{Postgres.PGUSER}}", DB_PASSWORD: "${{Postgres.PGPASSWORD}}",
            DB_DATABASE: "${{Postgres.PGDATABASE}}", DB_SSL: "false",
            REALTIME_PUBLIC_URL: $rt,
            REALTIME_INTERNAL_URL: "http://${{realtime.RAILWAY_PRIVATE_DOMAIN}}:1234",
            COMPILE_BACKEND: "cloudflare", COMPILE_WORKER_URL: $worker
          }'
          tf_railway_variables api
          passthrough "$PASSTHROUGH_API"
        } | merge_objects)"
        ;;
      realtime)
        set_variables realtime "$(jq -n '{
          KAXOLAX_SERVICE: "realtime", NODE_ENV: "production", LOG_LEVEL: "info",
          HOST: "::", PORT: "1234",
          DATABASE_URL: "${{Postgres.DATABASE_URL}}", DB_SSL: "false",
          REDIS_URL: "${{Redis.REDIS_URL}}",
          REALTIME_TOKEN_SECRET: "${{api.REALTIME_TOKEN_SECRET}}",
          INTERNAL_TOKEN: "${{api.INTERNAL_TOKEN}}"
        }')"
        ;;
      web | admin)
        set_variables "$name" "$({
          jq -n --arg svc "$name" --arg port "$(service_port "$name")" '{
            KAXOLAX_SERVICE: $svc, NODE_ENV: "production",
            HOSTNAME: "::", PORT: $port,
            # Lue au build (réécritures /api figées par next build) : Railway la passe en argument.
            API_INTERNAL_URL: "http://${{api.RAILWAY_PRIVATE_DOMAIN}}:3333"
          }'
          passthrough "$PASSTHROUGH_WEB"
          # Origines de la CSP du web (temps réel, URL présignées R2, galerie) : sans elles, le web
          # les relit sur l'API (GET /client-config) et l'annonce au démarrage.
          if [[ "$name" == web ]]; then
            jq -n --arg rt "wss://$HOST_REALTIME" '{REALTIME_PUBLIC_URL: $rt}'
            tf_railway_variables api |
              jq -c '{S3_PUBLIC_ENDPOINT, TEMPLATES_PUBLIC_URL, TEMPLATES_CATALOG_URL} | with_entries(select(.value != null))'
          fi
        } | merge_objects)"
        ;;
      backup)
        set_variables backup "$({
          jq -n '{
            DATABASE_URL: "${{Postgres.DATABASE_URL}}", BACKUP_PREFIX: "postgres",
            BACKUP_RETENTION_DAYS: "35", BACKUP_MIN_KEEP: "7"
          }'
          tf_railway_variables backup
          passthrough AGE_RECIPIENT
        } | merge_objects)"
        ;;
    esac
  done

  if [[ " $SERVICES " == *" backup "* && -z "${AGE_RECIPIENT:-}" && "$DRY_RUN" == 0 ]] &&
    [[ "$(existing_variables backup | jq -r 'has("AGE_RECIPIENT")')" != "true" ]]; then
    warn "backup : AGE_RECIPIENT non défini (la sauvegarde échouera ; age-keygen, docs/procedure.md)"
  fi
  if [[ " $SERVICES " == *" api "* && "$DRY_RUN" == 1 ]]; then
    check_smtp_tls '{}'
  fi
  if [[ " $SERVICES " == *" api "* && "$DRY_RUN" == 0 ]]; then
    local current key
    current="$(existing_variables api)"
    for key in $REQUIRED_API; do
      [[ "$(jq -r --arg k "$key" 'has($k)' <<<"$current")" == "true" ]] || warn "api : $key non défini (l'API ne démarrera pas)"
    done
    check_smtp_tls "$current"
    for key in $OBSOLETE_API; do
      [[ "$(jq -r --arg k "$key" 'has($k)' <<<"$current")" != "true" ]] ||
        warn "api : $key n'est plus lue (railway variable delete $key --service api)"
    done
  fi
}

# --- Domaines -----------------------------------------------------------------------------------

# Port d'écoute de chaque service (PORT posé ci-dessus, cible des domaines personnalisés).
service_port() {
  case "$1" in
    web) printf 3000 ;;
    admin) printf 3001 ;;
    api) printf 3333 ;;
    realtime) printf 1234 ;;
    *) die "service sans port : $1" ;;
  esac
}

ensure_domain() {
  local service="$1" fqdn="$2" port="$3"
  [[ " $SERVICES " == *" $service "* && -n "$(service_id "$service")" ]] || return 0
  if railway domain list --service "$service" --json | jq -e --arg d "$fqdn" '[.. | strings | select(. == $d)] | length > 0' >/dev/null; then
    return
  fi
  log "domaine $fqdn → $service:$port"
  mutate railway domain "$fqdn" --service "$service" --port "$port" --json
}

print_dns_targets() {
  local service fqdn pair
  log "enregistrements DNS demandés par Railway (à reporter dans railway_targets et extra_dns_records de cloudflare/terraform.tfvars) :"
  for pair in "web:$HOST_APP" "admin:$HOST_ADMIN" "api:$HOST_API" "realtime:$HOST_REALTIME"; do
    service="${pair%%:*}"
    fqdn="${pair#*:}"
    [[ " $SERVICES " == *" $service "* && -n "$(service_id "$service")" ]] || continue
    printf -- '--- %s (%s)\n' "$fqdn" "$service"
    railway domain status "$fqdn" --service "$service" --json || warn "statut de $fqdn indisponible"
  done
}

main() {
  require_tools
  load_terraform_outputs
  link_project

  refresh_status
  ensure_database "$PG_SERVICE" postgres
  ensure_database "$REDIS_SERVICE" redis
  local name
  for name in $SERVICES; do
    case "$name" in
      web | admin | api | realtime | backup) ensure_service "$name" "$PLATFORM_REPO" ;;
      *) die "service inconnu dans SERVICES : $name" ;;
    esac
  done

  refresh_status
  configure_variables
  apply_config_files
  apply_service_configs

  ensure_domain web "$HOST_APP" "$(service_port web)"
  ensure_domain admin "$HOST_ADMIN" "$(service_port admin)"
  ensure_domain api "$HOST_API" "$(service_port api)"
  ensure_domain realtime "$HOST_REALTIME" "$(service_port realtime)"
  [[ "$DRY_RUN" == 1 ]] || print_dns_targets

  log "terminé. Secret du Worker de compilation : même valeur que COMPILE_WORKER_SECRET de l'api"
  log "(railway variable list --service api --kv | grep COMPILE_WORKER_SECRET, puis wrangler secret put)."
}

main
