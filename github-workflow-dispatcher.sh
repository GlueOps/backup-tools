#!/bin/bash
set -e


curl \
  --fail \ 
  -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  ${GITHUB_DISPATCH_URL} \
  -d '{"ref":"refs/heads/main"}'