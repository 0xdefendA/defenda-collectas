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

variable "image" {
  description = "The container image to deploy"
  type        = string
}

variable "schedule" {
  description = "The cron schedule for triggering the collector"
  type        = string
}

variable "pubsub_topic_name" {
  description = "The name of the existing Pub/Sub topic"
  type        = string
  default     = "defenda-event-ingest"
}

variable "env_vars" {
  description = "Additional environment variables for the collector"
  type        = map(string)
  default     = {}
}

variable "secret_env_vars" {
  description = "Sensitive environment variables for the collector"
  type        = map(string)
  default     = {}
}
