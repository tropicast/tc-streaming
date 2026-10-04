#!/usr/bin/env bash
# Writes terraform.tfvars and backend.hcl from CI variables.
# Used by .github/workflows/terraform-deploy.yml.
set -euo pipefail

: "${TFVARS:?Set the TFVARS repository variable}"
: "${STATE_BUCKET:?Set the TF_STATE_BUCKET repository variable}"
: "${STATE_LOCATION:?Set the TF_STATE_LOCATION repository variable}"

cd "$(dirname "$0")"
printf '%s\n' "$TFVARS" > terraform.tfvars
cat > backend.hcl <<HCL
bucket = "$STATE_BUCKET"
key    = "tc-streaming/mvp.tfstate"
region = "$STATE_LOCATION"

endpoints = {
  s3 = "https://$STATE_LOCATION.your-objectstorage.com"
}

use_path_style              = true
skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_s3_checksum            = true
HCL
