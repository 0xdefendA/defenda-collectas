variable "project_id" {
  description = "The GCP Project ID where resources will be deployed"
  type        = string
}

variable "region" {
  description = "The GCP region for Cloud Run and Scheduler"
  type        = string
  default     = "us-central1"
}

variable "pubsub_topic_name" {
  description = "The name of the existing Pub/Sub topic to publish events to"
  type        = string
}

variable "collectors" {
  description = "A map of collector configurations to deploy"
  type = map(object({
    enabled       = bool
    schedule      = string
    env_vars      = map(string)
    secret_mounts = map(string) # Map ENV_VAR to Secret ID
  }))
  default = {}
}

variable "image_tag" {
  description = "The Docker image tag to deploy (e.g., git commit SHA or 'latest')"
  type        = string
  default     = "latest"
}

variable "enable_gcp_audit_sink" {
  description = "Route GCP Admin Activity audit logs into the ingest topic via a Cloud Logging sink"
  type        = bool
  default     = true
}

variable "organization_id" {
  description = "GCP organization ID for an org-level aggregated audit log sink; leave empty to fall back to a project-level sink"
  type        = string
  default     = ""
}
