#!/bin/bash
set -e

ACCOUNT_ID=$1
if [ -z "$ACCOUNT_ID" ]; then
    echo "Usage: $0 <ACCOUNT_ID>" >&2
    exit 1
fi

# Uses MGMT_... env vars to assume the role
export AWS_ACCESS_KEY_ID=$MGMT_AWS_ACCESS_KEY_ID
#
# THE FIX IS HERE:
export AWS_SECRET_ACCESS_KEY=$MGMT_AWS_SECRET_ACCESS_KEY
#
#

# 1. Assume the role
CREDS=$(aws sts assume-role \
    --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" \
    --role-session-name "GetBucketListSession" \
    --output json)

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to assume role for $ACCOUNT_ID" >&2
    exit 1
fi

# 2. Export temporary creds
export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.Credentials.SessionToken')

# 3. List the buckets and ignore loki buckets entirely
aws s3api list-buckets --query 'Buckets[?!contains(Name, `loki`) && !contains(Name, `hourly-cur`)].Name' --output text
