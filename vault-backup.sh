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
datetime=$(date +"%Y%m%d_%H%M%S")
s3_destination=${S3_BUCKET_NAME}/${CAPTAIN_DOMAIN}/hashicorp-vault-backups/${date}/vault_${datetime}.snap
aws s3 cp /app/vault_${date}.snap s3://${s3_destination}
unset VAULT_TOKEN
echo "Uploaded backup to s3. BUT we still need to validate the backup!!"
echo "Assuming vault-reader-role in vault"
export VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login jwt=$SA_TOKEN role=reader-role);
echo "Reading first secret available in current vault environment. if it was updated since the backup was taken then this backup may fail!"
FIRST_SECRET=$(vault list -format=json secret/metadata/ | jq -r '.[0]')
echo "Reading the data/values within the first secret"
VAULT_OUTPUT=$(vault read -format=json "secret/data/$FIRST_SECRET")
KEY_VALUES=$(echo $VAULT_OUTPUT | jq '.data.data')
echo "Getting s3 presigned url for vault backup"
BACKUP_S3_PRESIGNED_URL=$(aws s3 presign s3://${s3_destination} --expires-in 300)
echo "Getting s3 presigned url for vault access tokens"
TOKENS_S3_PRESIGNED_URL=$(aws s3 presign s3://${S3_BUCKET_NAME}/${CAPTAIN_DOMAIN}/hashicorp-vault-init/vault_access.json --expires-in 300)
BASE_JSON='{
    "source_backup_url": "'"$BACKUP_S3_PRESIGNED_URL"'",
    "source_keys_url": "'"$TOKENS_S3_PRESIGNED_URL"'",
    "path_values_map":{},
    "vault_version": "1.14.6"
}'
UPDATED_JSON=$(echo $BASE_JSON | jq --arg path "secret/$FIRST_SECRET" --argjson kv "$KEY_VALUES" '.path_values_map[$path] = $kv')
echo "Validating Backup now....."
curl glueops-backup-and-exports.glueops-core-backup.svc.cluster.local:8080/api/v1/validate --fail-with-body -X POST -d "${UPDATED_JSON}"
