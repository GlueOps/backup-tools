#!/bin/bash

set -e

# Check if required variables are set
if [[ -z "${RCLONE_DRIVE_SERVICE_ACCOUNT_CREDENTIALS}" ]]; then
    echo "Error: RCLONE_DRIVE_SERVICE_ACCOUNT_CREDENTIALS is not set."
    exit 1
fi

if [[ -z "${RCLONE_DRIVE_TEAM_DRIVE}" ]]; then
    echo "Error: RCLONE_DRIVE_TEAM_DRIVE is not set."
    exit 1
fi


BACKUP_DATE=$(date '+%Y-%m-%d')
BACKUP_LOCATION="google_drive_team_drives/$BACKUP_DATE/$RCLONE_DRIVE_TEAM_DRIVE"
mkdir -p $BACKUP_LOCATION

rclone copy -P --transfers=100  gdrive: "${BACKUP_LOCATION}"
tar -cf "${BACKUP_LOCATION}.tar" ${BACKUP_LOCATION} && rm -rf "${BACKUP_LOCATION}"


echo "Uploading everything to S3...."
cd /backups
aws s3 cp --recursive google_drive_team_drives/ s3://${S3_BUCKET_NAME}/google_drive_team_drives/