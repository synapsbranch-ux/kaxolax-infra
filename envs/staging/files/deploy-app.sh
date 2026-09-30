#!/bin/bash
# kaxolax-deploy (instance applicative) : configuration (S3), secrets (Secrets Manager), images
# (ECR), migrations, puis docker compose. Lancé au premier démarrage, puis par la CI via SSM.
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source /etc/kaxolax/deploy.env # REGION, CONFIG_URI
export AWS_REGION="$REGION" HOME=/root DOCKER_CONFIG=/root/.docker

dir=/opt/kaxolax
install -d -m 0755 "$dir" "$dir/certs"
install -d -m 0700 "$dir/env"
aws s3 cp --quiet --recursive "$CONFIG_URI" "$dir/"
# shellcheck source=/dev/null
source "$dir/deploy.env" # REGISTRY, SECRET_ID, CA_URI, COMPOSE_IMAGE
aws s3 cp --quiet "$CA_URI" "$dir/certs/rds-ca.pem"
# Lus par les conteneurs (utilisateur node pour le certificat).
chmod 0644 "$dir/certs/rds-ca.pem" "$dir/compose.yml" "$dir/Caddyfile"

secret=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text)

# add_secrets <fichier> <VARIABLE=clé>... : ajoute des secrets (non vides) au fichier d'environnement.
add_secrets() {
  local file=$1 pair value
  shift
  for pair in "$@"; do
    value=$(jq -er --arg key "${pair#*=}" '.[$key] | select(length > 0)' <<<"$secret")
    printf '%s=%s\n' "${pair%%=*}" "$value" >>"$dir/env/$file"
  done
}

add_secrets api.env APP_KEY=app_key DB_PASSWORD=db_password SMTP_USERNAME=smtp_username \
  SMTP_PASSWORD=smtp_password REALTIME_TOKEN_SECRET=realtime_token_secret INTERNAL_TOKEN=internal_token
add_secrets realtime.env DATABASE_URL=database_url REALTIME_TOKEN_SECRET=realtime_token_secret \
  INTERNAL_TOKEN=internal_token
add_secrets gateway.env INTERNAL_TOKEN=internal_token
add_secrets caddy.env ORIGIN_VERIFY_SECRET=origin_verify

aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

# Docker Compose vient de l'image docker:cli (le paquet docker d'AL2023 ne l'a pas). Mêmes chemins
# dans le conteneur et sur l'hôte : les montages du compose sont résolus par le démon de l'hôte.
compose() {
  docker run --rm \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    --volume "$dir:$dir" \
    --volume /root/.docker:/root/.docker:ro \
    --workdir "$dir" \
    "$COMPOSE_IMAGE" compose "$@"
}

compose pull --quiet
compose up --detach --wait redis
compose run --rm --no-deps api node build/ace.js migration:run --force
compose up --detach --wait --wait-timeout 300 --remove-orphans
docker image prune --force >/dev/null
echo "kaxolax-deploy: application deployed"
