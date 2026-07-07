# GCP audit log collection: a Cloud Logging sink routing Admin Activity
# audit logs into the existing defenda-event-ingest topic. No service, no
# cursor state — ingestA's gcp_audit normalization plugin handles the rest.
#
# Scope: org-level aggregated sink when organization_id is set (covers all
# current and future projects, including a future sacrificial detonation
# project); otherwise a per-project sink on the platform project.

locals {
  gcp_audit_sink_enabled = var.enable_gcp_audit_sink
  gcp_audit_org_scoped   = local.gcp_audit_sink_enabled && var.organization_id != ""
  gcp_audit_proj_scoped  = local.gcp_audit_sink_enabled && var.organization_id == ""

  # Admin Activity only (free, always on). Data Access logs are a later
  # phase and need platform service-account exclusions first.
  gcp_audit_filter = "logName:\"cloudaudit.googleapis.com%2Factivity\""

  gcp_audit_destination = "pubsub.googleapis.com/${data.google_pubsub_topic.existing_ingest.id}"
}

resource "google_logging_organization_sink" "gcp_audit" {
  count = local.gcp_audit_org_scoped ? 1 : 0

  name             = "defenda-gcp-audit"
  org_id           = var.organization_id
  include_children = true
  destination      = local.gcp_audit_destination
  filter           = local.gcp_audit_filter
}

resource "google_logging_project_sink" "gcp_audit" {
  count = local.gcp_audit_proj_scoped ? 1 : 0

  name                   = "defenda-gcp-audit"
  project                = var.project_id
  destination            = local.gcp_audit_destination
  filter                 = local.gcp_audit_filter
  unique_writer_identity = true
}

# The sink writes as a Google-managed service identity; it needs publish
# rights on the ingest topic.
resource "google_pubsub_topic_iam_member" "gcp_audit_sink_writer" {
  count = local.gcp_audit_sink_enabled ? 1 : 0

  topic = data.google_pubsub_topic.existing_ingest.id
  role  = "roles/pubsub.publisher"
  member = (
    local.gcp_audit_org_scoped
    ? google_logging_organization_sink.gcp_audit[0].writer_identity
    : google_logging_project_sink.gcp_audit[0].writer_identity
  )
}
