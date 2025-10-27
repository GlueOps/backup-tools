#!/bin/bash
set -e

ACCOUNT_ID=$1
SRC_BUCKET_NAME=$2

if [ -z "$ACCOUNT_ID" ] || [ -z "$SRC_BUCKET_NAME" ]; then
    echo "Usage: $0 <ACCOUNT_ID> <BUCKET_NAME>" >&2
    exit 1
fi

echo "--- Starting copy for $ACCOUNT_ID / $SRC_BUCKET_NAME ---"

# --- 1. DOWNLOAD ---
echo "Assuming role to download..."
# Uses MGMT_... env vars to assume the role
export AWS_ACCESS_KEY_ID=$MGMT_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$MGMT_AWS_SECRET_KEY
unset AWS_SESSION_TOKEN # Make sure this isn't set

CREDS=$(aws sts assume-role \
    --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" \
    --role-session-name "CopySession" \
    --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.Credentials.SessionToken')

echo "Downloading from $SRC_BUCKET_NAME..."
aws s3 cp s3://$SRC_BUCKET_NAME /tmp/s3_copy --recursive
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download $SRC_BUCKET_NAME. Skipping." >&2
    rm -rf /tmp/s3_copy # Clean up partial download
    exit 0 # Exit gracefully so the main script continues
fi

# --- 2. UPLOAD ---
echo "Switching to destination creds to upload..."
export AWS_ACCESS_KEY_ID=$DST_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$DST_AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN # CRITICAL: Unset the temporary session token

DEST_PATH="s3://$DST_BUCKET/s3_bucket_backups/$ACCOUNT_ID-$SRC_BUCKET_NAME"
echo "Uploading to $DEST_PATH..."
aws s3 cp /tmp/s3_copy $DEST_PATH --recursive

# --- 3. CLEANUP ---
echo "Cleaning up local directory..."
rm -rf /tmp/s3_copy

echo "--- Finished copy for $SRC_BUCKET_NAME ---"