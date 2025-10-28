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
#
# THE FIX IS HERE:
export AWS_SECRET_ACCESS_KEY=$MGMT_AWS_SECRET_ACCESS_KEY
#
#
unset AWS_SESSION_TOKEN # Make sure this isn't set

CREDS=$(aws sts assume-role \
    --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" \
    --role-session-name "CopySession" \
    --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.Credentials.SessionToken')

echo "Downloading from $SRC_BUCKET_NAME..."
rm -rf /tmp/s3_copy
aws s3 cp s3://$SRC_BUCKET_NAME /tmp/s3_copy --recursive
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download $SRC_BUCKET_NAME. Skipping." >&2
    rm -rf /tmp/s3_copy # Clean up partial download
    exit 0 # Exit gracefully so the main script continues
fi

# --- 1.5. TAR (NEW SECTION) ---
echo "Creating uncompressed tarball..."
DATE=$(date +'%Y%m%d')
# Changed extension to .tar since we are not gzipping
FILENAME="${DATE}-${ACCOUNT_ID}_${SRC_BUCKET_NAME}.tar"
TARBALL_PATH="/tmp/$FILENAME"
rm -f $TARBALL_PATH # Use -f to avoid error if it doesn't exist

# Create a plain .tar file (no 'z' flag) for no compression
# -C /tmp changes directory to /tmp so the tarball doesn't contain the /tmp/ path
tar -cf $TARBALL_PATH -C /tmp s3_copy
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create tarball for $SRC_BUCKET_NAME." >&2
    rm -rf /tmp/s3_copy # Clean up
    exit 0 # Exit gracefully
fi
echo "Created $TARBALL_PATH"

# --- 2. UPLOAD (MODIFIED) ---
echo "Switching to destination creds to upload..."
export AWS_ACCESS_KEY_ID=$DST_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$DST_AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN # CRITICAL: Unset the temporary session token

# Upload the single tarball file instead of the directory
DEST_PATH="s3://$DST_BUCKET/$FILENAME"
echo "Uploading to $DEST_PATH..."
aws s3 cp $TARBALL_PATH $DEST_PATH
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to upload $TARBALL_PATH." >&2
    # Continue to cleanup
else
    echo "Upload successful."
fi


# --- 3. CLEANUP (MODIFIED) ---
echo "Cleaning up local directory and tarball..."
rm -rf /tmp/s3_copy
rm -f $TARBALL_PATH # Also remove the generated tarball

echo "--- Finished copy for $SRC_BUCKET_NAME ---"

