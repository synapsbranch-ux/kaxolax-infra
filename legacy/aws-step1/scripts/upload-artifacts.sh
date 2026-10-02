#!/usr/bin/env bash
# Dépose dans le bucket d'artefacts du staging ce que les instances, sans accès à internet, ne
# peuvent pas télécharger elles-mêmes : gVisor (runsc) pour le worker, certificats de RDS pour
# l'API et le temps réel.
# Usage : scripts/upload-artifacts.sh <bucket> <release gVisor>
#   (valeurs : terraform -chdir=envs/staging output -raw artifacts_bucket / gvisor_release)
set -euo pipefail

bucket=${1:?usage: scripts/upload-artifacts.sh <bucket> <gvisor release>}
release=${2:?usage: scripts/upload-artifacts.sh <bucket> <gvisor release>}
arch=aarch64 # instances Graviton
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

url="https://storage.googleapis.com/gvisor/releases/release/${release}/${arch}"
curl -fsSLO "${url}/gvisor.tar.bz2"
curl -fsSLO "${url}/gvisor.tar.bz2.sha512"
sha512sum --check gvisor.tar.bz2.sha512
for file in gvisor.tar.bz2 gvisor.tar.bz2.sha512; do
  aws s3 cp --only-show-errors "$file" "s3://${bucket}/gvisor/${release}/${arch}/${file}"
done

curl -fsSL -o rds-ca.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
grep -q 'BEGIN CERTIFICATE' rds-ca.pem
aws s3 cp --only-show-errors rds-ca.pem "s3://${bucket}/certs/rds-ca.pem"

echo "uploaded gVisor ${release} (${arch}) and the RDS CA bundle to s3://${bucket}"
