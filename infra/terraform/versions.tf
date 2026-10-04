terraform {
  required_version = ">= 1.10"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.54"
    }
  }

  # Remote state settings come from backend.hcl; see backend.hcl.example.
  backend "s3" {}
}

# Reads the API token from the HCLOUD_TOKEN environment variable.
provider "hcloud" {}
