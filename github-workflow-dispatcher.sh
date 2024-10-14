#!/bin/bash
set -e



# Check if required variables are set
if [ -z "${GITHUB_DISPATCH_URL}" ]; then
    echo "Error: GITHUB_DISPATCH_URL is not set."
    exit 1
fi

if [ -z "${REF_NAME}" ]; then
    echo "Error: REF_NAME is not set."
    exit 1
fi

curl \
  --fail \
  -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  ${GITHUB_DISPATCH_URL} \
  -d "{\"ref\":\"${REF_NAME}\"}" 