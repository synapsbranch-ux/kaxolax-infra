# Archive : staging AWS de l'étape 1

Terraform du staging AWS de l'étape 1 (bootstrap, réseau sans internet, CloudFront par VPC
origin, instances EC2 avec Docker Compose, worker gVisor, RDS PostgreSQL 18, S3, SES). **Plus
appliqué ni validé par la CI** : la décision C.2 de l'étape 2 remplace AWS par Railway et
Cloudflare (voir le [README](../../README.md) et [docs/architecture.md](../../docs/architecture.md)).

**Si le staging AWS tourne encore, le détruire d'abord**, avant toute autre opération sur ce
dossier et avant de le supprimer du dépôt : ses instances EC2, RDS, endpoints VPC, dépôts ECR et
buckets restent facturés, et ce Terraform (avec son état S3) est le seul moyen propre de les
retirer (procédure ci-dessous). Contrôle après destruction : `aws resourcegroupstaggingapi
get-resources --tag-filters Key=Project,Values=kaxolax`, dans le compte et la région du staging,
ne renvoie plus de ressource.

Conservé tel quel, chemins relatifs inchangés (`envs/staging` → `../../modules`), pour :

- relire les choix de l'étape 1 (journal de l'époque : [docs/decisions.md](../../docs/decisions.md),
  entrées du 2026-09-30) ;
- détruire un staging encore déployé : depuis `legacy/aws-step1/envs/staging`, même état S3
  qu'avant (`terraform init -backend-config="bucket=…"`), `db_deletion_protection = false`,
  `apply`, puis `terraform destroy` ; enfin `bootstrap/` (bucket d'état, rôles, ECR).

À supprimer du dépôt une fois le staging AWS détruit (l'historique git le garde).
