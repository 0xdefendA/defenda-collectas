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
  default     = "defenda-event-ingest"
}

variable "collectors" {
  description = "A map of collector configurations to deploy"
  type = map(object({
    enabled         = bool
    image           = string
    schedule        = string
    env_vars        = map(string)
    secret_env_vars = map(string)
  }))
  default = {}
}
