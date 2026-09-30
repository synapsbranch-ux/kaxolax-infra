#!/bin/bash
# kaxolax-deploy (worker) : configuration (S3), jeton interne (Secrets Manager), images (ECR), puis
# conteneur de l'agent de compilation. Lancé au premier démarrage, puis par la CI via SSM.
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source /etc/kaxolax/deploy.env # REGION, CONFIG_URI
export AWS_REGION="$REGION" HOME=/root DOCKER_CONFIG=/root/.docker

config=/etc/kaxolax/current
rm -rf "$config.new"
install -d -m 0700 "$config.new"
aws s3 cp --quiet --recursive "$CONFIG_URI" "$config.new/"
rm -rf "$config"
mv "$config.new" "$config"
# shellcheck source=/dev/null
source "$config/deploy.env" # REGISTRY, SECRET_ID, AGENT_IMAGE, TEXLIVE_IMAGE

token=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text |
  jq -er '.internal_token | select(length > 0)')
printf 'INTERNAL_TOKEN=%s\n' "$token" >>"$config/agent.env"

aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker pull --quiet "$TEXLIVE_IMAGE"
docker pull --quiet "$AGENT_IMAGE"

# Le socket Docker est monté dans l'agent seulement, jamais dans les conteneurs de compilation.
# Mêmes chemins dans l'agent et sur l'hôte : l'agent y monte le répertoire de chaque projet.
install -d -m 0755 /var/lib/kaxolax
docker rm --force compile-agent >/dev/null 2>&1 || true
docker run --detach --name compile-agent --restart unless-stopped \
  --publish 3200:3200 \
  --env-file "$config/agent.env" \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume /var/lib/kaxolax:/var/lib/kaxolax \
  --security-opt no-new-privileges:true \
  --log-driver local \
  "$AGENT_IMAGE"

for _ in $(seq 1 30); do
  if curl --silent --fail --output /dev/null --header @<(printf 'X-Internal-Token: %s\n' "$token") \
    http://127.0.0.1:3200/health; then
    docker image prune --force >/dev/null
    echo "kaxolax-deploy: compile agent deployed"
    exit 0
  fi
  sleep 2
done
docker logs --tail 50 compile-agent
exit 1
