# GCP audit log collection: a Cloud Logging sink routing Cloud Audit Logs into
# the existing defenda-event-ingest topic. No service, no cursor state — ingestA's
# gcp_audit normalization plugin handles the rest.
#
# Scope: org-level aggregated sink when organization_id is set (covers all current
# and future projects, including ephemeral huntA detonation projects); otherwise a
# per-project sink on the platform project.
#
# ---------------------------------------------------------------------------
# WHY DATA ACCESS LOGS ARE HERE (huntA phase 2a)
#
# Admin Activity logs are always on and free. Data Access logs are OFF by default,
# and they are the difference between seeing service-account impersonation /
# secret retrieval and being structurally blind to it. That was never a detection
# problem — it was a collection problem wearing a detection problem's clothes.
#
# These are enabled ORG-WIDE on purpose. The alternative considered was enabling
# them only in the sacrificial detonation project, which would have been worse
# than useless: a hunt agent would learn to hunt on GenerateAccessToken, write a
# skill keyed on it, score perfectly against its eval fixture forever — and detect
# nothing in production, because no other project emits those logs. A skill that
# passes evals and detects nothing is worse than no skill; it makes the coverage
# map lie. Detonation telemetry must match the production telemetry surface, or
# the seed loop encodes fiction.
# ---------------------------------------------------------------------------

locals {
  gcp_audit_sink_enabled = var.enable_gcp_audit_sink
  gcp_audit_org_scoped   = local.gcp_audit_sink_enabled && var.organization_id != ""
  gcp_audit_proj_scoped  = local.gcp_audit_sink_enabled && var.organization_id == ""

  gcp_audit_data_access_enabled = local.gcp_audit_sink_enabled && var.enable_data_access_logs

  # Admin Activity (always on, free) plus — when enabled — Data Access.
  # NOTE the log name suffixes are exact and easy to fumble:
  #   %2Factivity      Admin Activity   (always written, free)
  #   %2Fdata_access   Data Access      (off by default, chargeable)
  #   %2Fsystem_event  System Event     (always written, free)
  #   %2Fpolicy        Policy Denied    (NOT %2Fpolicy_denied)
  gcp_audit_filter = (
    local.gcp_audit_data_access_enabled
    ? "logName:\"cloudaudit.googleapis.com%2Factivity\" OR logName:\"cloudaudit.googleapis.com%2Fdata_access\""
    : "logName:\"cloudaudit.googleapis.com%2Factivity\""
  )

  gcp_audit_destination = "pubsub.googleapis.com/${data.google_pubsub_topic.existing_ingest.id}"
}

# --- Data Access audit configuration -----------------------------------------
#
# READ THIS BEFORE CHANGING log_type VALUES. The obvious config is wrong:
#
#   * iam.googleapis.com has NO DATA_READ methods at all. A DATA_READ block on it
#     applies cleanly in terraform and does exactly nothing.
#
#   * GenerateAccessToken — service-account impersonation, the single highest-value
#     cloud lateral-movement signal — is ADMIN_READ, not DATA_READ.
#
#   * iamcredentials.googleapis.com CANNOT be configured independently. It rides on
#     iam.googleapis.com. Naming it here would apply and silently no-op.
#
# So ADMIN_READ on iam.googleapis.com is the line that actually buys impersonation
# visibility, and it is the one a reasonable person would have left out.
#
# Org-level config is inherited by all current and future projects and cannot be
# weakened by a child project (configs union; a project may add logging and add
# exemptions, but never remove what the org set).
resource "google_organization_iam_audit_config" "data_access" {
  for_each = local.gcp_audit_data_access_enabled && local.gcp_audit_org_scoped ? toset(var.data_access_services) : toset([])

  org_id  = var.organization_id
  service = each.key

  # ADMIN_READ: metadata/config reads. This is where GenerateAccessToken,
  # TestIamPermissions, GetIamPolicy, ListServiceAccountKeys, and Secret Manager
  # enumeration live — i.e. most of the recon and impersonation signal.
  audit_log_config {
    log_type = "ADMIN_READ"
  }

  # DATA_READ: actual data reads. AccessSecretVersion (the real secret retrieval)
  # and GCS object reads.
  audit_log_config {
    log_type = "DATA_READ"
  }
}

# Project-scoped fallback for orgless deployments. Same log_type reasoning.
resource "google_project_iam_audit_config" "data_access" {
  for_each = local.gcp_audit_data_access_enabled && local.gcp_audit_proj_scoped ? toset(var.data_access_services) : toset([])

  project = var.project_id
  service = each.key

  audit_log_config {
    log_type = "ADMIN_READ"
  }

  audit_log_config {
    log_type = "DATA_READ"
  }
}

# --- Sinks --------------------------------------------------------------------

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

# The sink writes as a Google-managed service identity; it needs publish rights on
# the ingest topic.
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
