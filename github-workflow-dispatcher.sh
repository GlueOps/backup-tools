#!/bin/bash
set -e



check_variable() {
    local var_name=$1
    local var_value=${!var_name}
    
    if [ -z "${var_value}" ]; then
        echo "Error: ${var_name} is not set."
        exit 1
    fi
}

# List of required variables
required_vars=("GITHUB_DISPATCH_URL" "GITHUB_TOKEN" "REF_NAME")

# Check each variable
for var in "${required_vars[@]}"; do
    check_variable "$var"
done


curl \
  --fail \
  -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  ${GITHUB_DISPATCH_URL} \
  -d "{\"ref\":\"${REF_NAME}\"}" 