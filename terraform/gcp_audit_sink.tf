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

  # Whether to ROUTE Data Access logs. Enabling their GENERATION is a separate,
  # human-run step (scripts/enable_data_access_logs.py) — see the note below.
  # Routing logs that are not being generated is harmless: the filter simply
  # matches nothing.
  gcp_audit_data_access_enabled = local.gcp_audit_sink_enabled && var.route_data_access_logs

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

# --- Data Access audit configuration is NOT managed here ----------------------
#
# Deliberate. See scripts/enable_data_access_logs.py and SETUP.md.
#
# Enabling Data Access logs means editing the ORG's IAM policy (auditConfigs live
# inside it), which requires resourcemanager.organizations.setIamPolicy — i.e.
# Organization Administrator. Three reasons that does not belong in this terraform:
#
#   1. The deployer SA runs `terraform apply -auto-approve` from a GitHub Actions
#      runner. Granting it org setIamPolicy means anyone who can land a commit,
#      compromise a third-party Action, or poison a workflow dep can own the org.
#      Compare roles/logging.configWriter (below), which only says "can create
#      sinks" — narrow and contained. There is no equivalently narrow role here.
#
#   2. Control over audit logging IS the ability to turn off the telemetry defendA
#      runs on. That is literally an attack technique
#      (stratus gcp.defense-evasion.disable-audit-logs). Handing it to a
#      push-triggered pipeline is self-defeating for a security platform.
#
#   3. google_*_iam_audit_config is AUTHORITATIVE per service. A state loss, bad
#      refresh, or terraform destroy could REMOVE audit logging org-wide. IaC
#      should not hold a live switch that blinds the SIEM.
#
# Instead: Data Access logging is a PREREQUISITE the operator enables once, like
# enabling the Workspace Admin API for that collector. This matters for the
# portfolio deployment model too — you will not (and should not) get org-admin in
# a client's org.
#
# Drift is handled by DETECTION rather than by state, which is more in the spirit
# of the platform: the defenda_hunting.feed_coverage view shows whether
# data_access events are actually arriving, and a tripwire rule alerts on anyone
# modifying auditConfigs or this sink. defendA watches its own control plane.

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
