# Coolify Terraform Provider — connectivity probe.
#
# The 30-second sanity check: does the provider exist in the registry,
# can it authenticate against ml-capstone-admin.cs.byu.edu, and does it
# talk to Coolify's REST API cleanly?
#
# Usage:
#   cd terraform/probe
#   terraform init                                        # download the provider
#   TF_VAR_coolify_token=<your-token> terraform plan      # or -var=coolify_token=...
#
# If plan produces an output block with a real team ID, we're good —
# the provider is compatible with your Coolify version's API surface.

terraform {
  required_version = ">= 1.5"
  required_providers {
    coolify = {
      source  = "bindtech-xyz/coolify"
      version = "~> 0.1.0"
    }
  }
}

variable "coolify_token" {
  description = "Coolify API token — root-scope or team-scope with read access"
  type        = string
  sensitive   = true
}

provider "coolify" {
  endpoint = "https://ml-capstone-admin.cs.byu.edu/api/v1"
  token    = var.coolify_token
}

# Write-path probe. Project scoping is by the token's team context, so the
# Project lands in whichever team owns the token. Verify by checking Coolify
# UI after `terraform apply`. Follow up with `terraform destroy` to clean.
resource "coolify_project" "write_probe" {
  name        = "tf-probe-DELETE-ME"
  description = "Temporary - created by terraform/probe to verify writes."
}

resource "coolify_environment" "staging" {
  project_uuid = coolify_project.write_probe.uuid
  name         = "staging"
  description  = "Test environment"
}

resource "coolify_application" "hello_staging" {
  project_uuid     = coolify_project.write_probe.uuid
  environment_uuid = coolify_environment.staging.uuid
  server_uuid      = "n1wne6tvlebvws9zcuz6c1cg"
  destination_uuid = "i12hh0u2pljlnnxrdj0g11xi"
  github_app_uuid  = "onb2ftjqxx6lxxqwa20ku6ve"
  git_repository   = "byu-ml-capstone/qsnell-hello-world-app"
  git_branch       = "staging"
  build_pack       = "dockercompose"
  ports_exposes    = "8000"
}

output "created_project_uuid"     { value = coolify_project.write_probe.uuid }
output "created_environment_uuid" { value = coolify_environment.staging.uuid }
output "created_app_uuid"         { value = coolify_application.hello_staging.uuid }
