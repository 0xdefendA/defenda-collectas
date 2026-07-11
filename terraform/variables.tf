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
  description = "Route GCP audit logs into the ingest topic via a Cloud Logging sink"
  type        = bool
  default     = true
}

variable "organization_id" {
  description = "GCP organization ID for an org-level aggregated audit log sink; leave empty to fall back to a project-level sink"
  type        = string
  default     = ""
}

variable "route_data_access_logs" {
  description = <<-DESC
    Include Data Access audit logs in the sink filter.

    This only ROUTES them. GENERATING them requires editing the org IAM policy
    (auditConfigs live inside it), which needs Organization Administrator — not
    something the CI deployer should ever hold. That is a one-off human step:

        python scripts/enable_data_access_logs.py --org-id <ORG> --apply

    See SETUP.md. Leaving this true while Data Access logging is not yet enabled is
    harmless: the filter matches nothing until it is.

    Why it matters: without Data Access logs, service-account impersonation
    (GenerateAccessToken) and secret retrieval (AccessSecretVersion) are invisible,
    and every credential-access hunt returns empty no matter how good the agent is.
    Empty looks exactly like a quiet environment -- check
    defenda_hunting.feed_coverage before believing it.
  DESC
  type        = bool
  default     = true
}
