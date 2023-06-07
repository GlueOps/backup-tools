#!/bin/bash

set -e


date=$(date '+%Y-%m-%d')
echo "Starting Vault backup...@ ${date}"
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token);
export VAULT_LOG_LEVEL=debug
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login jwt=$SA_TOKEN role=vault-backup-role);

mkdir -p /backups/${date}
vault operator raft snapshot save /backups/vault_${date}.snap;

aws s3 cp /backups/vault_$(date '+%Y-%m-%d').snap s3://glueops-tenant-nil-primary/nil/hashicorp-vault-backups/$(date '+%Y-%m-%d')/vault_$(date +"%Y%m%d_%H%M%S").snap;

echo "Finished Vault backup."
