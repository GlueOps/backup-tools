#!/bin/bash
set -e

# Uses MGMT_... env vars
export AWS_ACCESS_KEY_ID=$MGMT_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$MGMT_AWS_SECRET_ACCESS_KEY

# Get all active account IDs, one per line
aws organizations list-accounts \
    --query "Accounts[?Status=='ACTIVE'].Id" \
    --output text