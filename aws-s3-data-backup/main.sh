#!/bin/bash
set -e

# --- Configuration ---
# (Configuration section is unchanged)
if [ -z "$DST_AWS_ACCESS_KEY_ID" ] || [ -z "$DST_AWS_SECRET_ACCESS_KEY" ] || [ -z "$DST_BUCKET" ] || \
   [ -z "$MGMT_AWS_ACCESS_KEY_ID" ] || [ -z "$MGMT_AWS_SECRET_ACCESS_KEY" ] || [ -z "$ROLE_NAME" ]; then
    echo "One or more required env vars are not set."
    echo "Please export: DST_..., MGMT_..., and ROLE_NAME"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    echo "jq could not be found. Please install it."
    exit 1
fi

# Export vars so the sub-scripts can use them
export DST_AWS_ACCESS_KEY_ID
export DST_AWS_SECRET_ACCESS_KEY
export DST_BUCKET
export MGMT_AWS_ACCESS_KEY_ID
export MGMT_AWS_SECRET_ACCESS_KEY
export ROLE_NAME
# --- End Configuration ---


echo "Starting backup process..."

# Get all accounts
#
# === MODIFICATION HERE ===
# Read both ID and Name from the script. IFS=$'\t' handles the tab separator.
./get_accounts.sh | while IFS=$'\t' read -r ACCOUNT_ID ACCOUNT_NAME
do
    echo "================================================="
    # Print both variables
    echo "Processing Account: $ACCOUNT_ID ($ACCOUNT_NAME)"
    # === END MODIFICATION ===

    # For this account, get all buckets
    for BUCKET_NAME in $(./get_buckets.sh $ACCOUNT_ID)
    do
        # Copy this one bucket
        ./copy_bucket.sh $ACCOUNT_ID $BUCKET_NAME
    done

    echo "================================================="
    echo ""
done

echo "All accounts processed."