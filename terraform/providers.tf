terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # Replace with your GCS bucket for remote state
  # backend "gcs" {
  #   bucket = "YOUR_TERRAFORM_STATE_BUCKET"
  #   prefix = "defenda-collectas/state"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
