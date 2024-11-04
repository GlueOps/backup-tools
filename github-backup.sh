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
    
    # Replace newlines with commas in the current page's orgs
    orgs_comma=$(echo "$orgs" | paste -sd "," -)

    # Append current orgs to all_orgs with a comma separator
    if [ -z "$all_orgs" ]; then
        all_orgs="$orgs_comma"
    else
        all_orgs="$all_orgs,$orgs_comma"
    fi

    # Increment the page number
    page=$((page + 1))
done


# Save the original IFS
OLD_IFS="$IFS"

# Set IFS to comma for splitting
IFS=','

# Read the all_orgs into positional parameters
set -- $all_orgs

# Restore the original IFS
IFS="$OLD_IFS"

echo "Full list to be backed up: $all_orgs"

for GITHUB_ORG_TO_BACKUP in "$@"; do
        echo ""
        echo ""
        
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
