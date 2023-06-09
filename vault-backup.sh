#!/bin/bash

set -e


date=$(date '+%Y-%m-%d')
echo "Starting Vault backup...@ ${date}"
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token);
export VAULT_LOG_LEVEL=debug
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login jwt=$SA_TOKEN role=vault-backup-role);

mkdir -p /app/${date}
vault operator raft snapshot save /app/vault_${date}.snap;

aws s3 cp /app/vault_$(date '+%Y-%m-%d').snap s3://${S3_BUCKET_NAME}/${CAPTAIN_DOMAIN}/hashicorp-vault-backups/$(date '+%Y-%m-%d')/vault_$(date +"%Y%m%d_%H%M%S").snap;

echo "Finished Vault backup."
