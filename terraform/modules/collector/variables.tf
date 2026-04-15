variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
}

variable "name" {
  description = "The name of the collector (e.g., google_workspace, okta)"
  type        = string
}

variable "schedule" {
  description = "The cron schedule for triggering the collector"
  type        = string
}

variable "pubsub_topic_name" {
  description = "The name of the existing Pub/Sub topic"
  type        = string
}

variable "env_vars" {
  description = "Non-sensitive environment variables"
  type        = map(string)
  default     = {}
}

variable "secret_mounts" {
  description = "A map of ENV_VAR_NAME to Secret Manager Secret ID for sensitive data"
  type        = map(string)
  default     = {}
}

variable "image_tag" {
  description = "The docker image tag to use for this collector"
  type        = string
  default     = "latest"
}
