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

variable "enable_data_access_logs" {
  description = <<-DESC
    Enable Data Access audit logs org-wide and route them to the ingest topic.

    Off by default in GCP. Without these, service-account impersonation
    (GenerateAccessToken) and secret retrieval (AccessSecretVersion) are invisible
    — every credential-access hunt returns empty no matter how good the agent is.

    Enabled ORG-WIDE deliberately, not just in the huntA detonation project. A
    detonation project richer than production would teach hunt agents to write
    skills against telemetry that does not exist anywhere else: perfect eval
    scores, zero production detections, and a coverage map that lies.

    Data Access logs are chargeable (unlike Admin Activity). Scoped to the
    services below rather than allServices.
  DESC
  type        = bool
  default     = true
}

variable "data_access_services" {
  description = <<-DESC
    Services to enable Data Access audit logs on. Both ADMIN_READ and DATA_READ are
    set for each — see the log_type notes in gcp_audit_sink.tf before trimming
    either, because the intuitive choice is wrong:

      * iam.googleapis.com has NO DATA_READ methods; ADMIN_READ is what matters.
      * GenerateAccessToken (SA impersonation) is ADMIN_READ, not DATA_READ.
      * iamcredentials.googleapis.com cannot be configured independently — it rides
        on iam.googleapis.com, so listing it here would silently no-op.

    bigquery.googleapis.com is deliberately absent: its Data Access logs are always
    on and cannot be disabled.
  DESC
  type        = list(string)
  default = [
    "iam.googleapis.com",           # + iamcredentials: impersonation, key/policy recon
    "secretmanager.googleapis.com", # AccessSecretVersion + secret enumeration
    "storage.googleapis.com",       # GCS object reads (highest volume of the three)
  ]
}
