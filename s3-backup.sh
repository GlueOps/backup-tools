#!/bin/zsh
setopt ERR_EXIT
setopt PIPE_FAIL

# Ensure all required environment variables are set
if [ -z "$SRC_AWS_ACCESS_KEY_ID" ] || [ -z "$SRC_AWS_SECRET_ACCESS_KEY" ] || [ -z "$DST_AWS_ACCESS_KEY_ID" ] || [ -z "$DST_AWS_SECRET_ACCESS_KEY" ] || [ -z "$SRC_BUCKET" ] || [ -z "$DST_BUCKET" ]; then
    echo "One or more required environment variables are not set."
    exit 1
fi

# Configure AWS CLI for source account
export AWS_ACCESS_KEY_ID=$SRC_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$SRC_AWS_SECRET_ACCESS_KEY

# Copy data from source bucket to a local directory
aws s3 cp s3://$SRC_BUCKET /tmp/s3_copy --recursive

# Configure AWS CLI for destination account
export AWS_ACCESS_KEY_ID=$DST_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$DST_AWS_SECRET_ACCESS_KEY

# Copy data from local directory to destination bucket
aws s3 cp /tmp/s3_copy s3://$DST_BUCKET/s3_bucket_backups/$SRC_BUCKET --recursive

# Clean up the local directory
rm -rf /tmp/s3_copy
