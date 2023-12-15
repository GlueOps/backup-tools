#!/bin/bash
set -e

cleanup() {
  echo "Cleaning up..."
  rm -rf *.part* || true
}

cleanup

s3_key_prefix="${CAPTAIN_DOMAIN}/loki_exported_logs"

aws sts get-caller-identity

# Check to see if LOGCLI and LOKI API/SERVER are running the same version. We don't want to have a weird bug caused by a version mismatch.
LOGCLI_VERSION=$(logcli --version 2>&1 | grep -oP 'logcli, version \K[0-9.]+' | awk '{print $1}')
LOKI_SERVER_VERSION=$(curl $LOKI_ADDR/loki/api/v1/status/buildinfo -s | jq .version -r)

loki_version_info() {
  echo "LOGCLI_VERSION: $LOGCLI_VERSION"
  echo "LOKI_SERVER_VERSION: $LOKI_SERVER_VERSION"
}

if [ "$LOGCLI_VERSION" != "$LOKI_SERVER_VERSION" ]; then
  echo "ERROR: The LOGCLI and Loki API versions do not match. Exiting the script."
  loki_version_info
  exit 1
fi

ERRORS=0

# Loop through the last 72 hours, excluding the most recent 2 hours
for i in {2..72}; do
  echo "Processing hour $i"

  # Get the date and time
  now=$(date -u -d "${i} hours ago" '+%Y-%m-%dT%H:00:00Z')
  start_time=$(date -u -d "$now - 1 hour" '+%Y-%m-%dT%H:00:00Z')
  echo "start_time: $start_time"
  end_time=$(date -u -d "$now" '+%Y-%m-%dT%H:00:00Z')
  echo "end_time: $end_time"

  # Prepare part file name
  prefix_file_name="loki_v${LOGCLI_VERSION//./-}__"
  time_window_of_logs="$(date -u -d "$start_time" '+%Y%m%dT%H%M%S')_$(date -u -d "$end_time" '+%Y%m%dT%H%M%S').part"
  part_file="${prefix_file_name}${time_window_of_logs}"
  echo "part_file: $part_file"

  # Prepare S3 path
  S3_FOLDER_PATH="${s3_key_prefix}/$(date -u -d "$start_time" '+%Y/%m/%d/%H')/"
  s3_path="${S3_FOLDER_PATH}${part_file}.gz"
  echo "s3_path: $s3_path"

  # Check if the file already exists in S3 and has been replicated.
  existing_files=$(aws s3api list-objects --bucket "$S3_BUCKET_NAME" --prefix "$S3_FOLDER_PATH" --query 'Contents[].Key' --output text)
  for file in $existing_files; do
      if [[ $file == *"$time_window_of_logs"* ]]; then
      echo "The ${file} already exists in S3. Skipping the upload."
      continue
      fi
  done



  # Query Loki and create part file. The part file will be created in the current directory.
  logcli query '{job=~".+"}' --output jsonl --timezone=UTC --tls-skip-verify --from "$start_time" --to "$end_time" --parallel-max-workers=2 --parallel-duration=120m --part-path-prefix=$(pwd)/$prefix_file_name

  # Check for multiple part files. This should never since each parallel-duration is 2 hours which exceeds the requested time range of 1 hour.
  part_files_count=$(ls -1 *.part 2>/dev/null | wc -l)

  if [ "$part_files_count" -gt 1 ]; then
    echo "Error: Found multiple part files. There should only be 1 part file. Skipping to the next hour."
    ERRORS += 1
    cleanup
    continue
  fi

  part_file=$(ls *.part | head -n 1)

  # Gzip and upload the part file to S3
  gzip "$part_file"
  aws s3 cp "${part_file}.gz" "s3://${S3_BUCKET_NAME}/${s3_path}"

  cleanup

done

if [ "$ERRORS" -gt 0 ]; then
  echo "ERROR: Found $ERRORS errors. Exiting the script."
  exit 1
fi