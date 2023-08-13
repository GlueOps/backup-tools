#!/bin/bash

set -e

# Check if required variables are set
if [[ -z "${GITHUB_ORG_TO_BACKUP}" ]]; then
    echo "Error: GITHUB_ORG_TO_BACKUP is not set."
    exit 1
fi

if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "Error: GITHUB_TOKEN is not set."
    exit 1
fi

repos=$(gh repo list $GITHUB_ORG_TO_BACKUP -L 100000 --json nameWithOwner -q '.[].nameWithOwner')

BACKUP_DATE=$(date '+%Y-%m-%d')
BACKUP_LOCATION="github.com/$BACKUP_DATE/$GITHUB_ORG_TO_BACKUP"
mkdir -p $BACKUP_LOCATION && cd $BACKUP_LOCATION

for repo in $repos; do
    # this is an empty dir and required for FORKed repos
    mkdir $repo
    gh repo clone https://github.com/$repo.git -- --mirror 
    # this should be an empty folder and should error if it's not empty
    rmdir  $repo
    repo_name="${repo##*/}"
    tar -czf "${repo_name}.tar.gz" "${repo_name}.git" && rm -rf "${repo_name}.git"
done

echo "Uploading everything to S3...."
cd /app
aws s3 cp --recursive github.com/ s3://${S3_BUCKET_NAME}/github.com/
