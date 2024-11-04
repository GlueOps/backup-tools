#!/bin/bash

set -e

if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "Error: GITHUB_TOKEN is not set."
    exit 1
fi


# Initialize page number
page=1
all_orgs=""

# Loop until we get an empty response
while true; do
    # Fetch organizations for the current page
    orgs=$(gh api "/user/orgs?page=$page" --jq '.[].login')

    # Check if the response is empty, meaning no more orgs
    if [ -z "$orgs" ]; then
        break
    fi

    # Append organizations to the all_orgs variable
    all_orgs="$all_orgs,$orgs"

    # Increment the page number
    page=$((page + 1))
done


echo "Full list to be backed up: $all_orgs"

for GITHUB_ORG_TO_BACKUP in "$@"; do
        echo "\n\n"
        echo "STARTING BACKUP OF: https://github.com/${GITHUB_ORG_TO_BACKUP}"

        repos=$(gh repo list $GITHUB_ORG_TO_BACKUP -L 100000 --json nameWithOwner -q '.[].nameWithOwner')

        BACKUP_DATE=$(date '+%Y-%m-%d')
        BACKUP_LOCATION="github.com/$BACKUP_DATE/$GITHUB_ORG_TO_BACKUP"
        mkdir -p $BACKUP_LOCATION && cd $BACKUP_LOCATION

        for repo in $repos; do
            git clone --mirror https://$GITHUB_TOKEN@github.com/$repo.git
            repo_name="${repo##*/}"
            tar -czf "${repo_name}.tar.gz" "${repo_name}.git" && rm -rf "${repo_name}.git"
        done

        echo "Uploading everything to S3...."
        cd /app
        aws s3 cp --recursive github.com/ s3://${S3_BUCKET_NAME}/github.com/
        rm -rf github.com/


        echo "FINISHED BACKUP OF: https://github.com/${GITHUB_ORG_TO_BACKUP}"
done
