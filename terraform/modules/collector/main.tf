resource "google_service_account" "collector_sa" {
  account_id   = "${var.name}-collector-sa"
  display_name = "Service Account for ${var.name} collector"
}

resource "google_parameter_manager_regional_parameter" "state_parameter" {
  parameter_id = "${var.name}-collector-state"
  location     = var.region
}

# Ensure the mounted secrets exist in Secret Manager
resource "google_secret_manager_secret" "mounted_secrets" {
  for_each  = var.secret_mounts
  secret_id = each.value
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_cloud_run_v2_service" "service" {
  name     = "${var.name}-collector"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.collector_sa.email
    containers {
      # AUTOMATIC IMAGE INFERENCE: Constructed from project, region, and collector name
      image = "${var.region}-docker.pkg.dev/${var.project_id}/collectors/${var.name}-collector:latest"

      ports {
        container_port = 8080
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "PUBSUB_TOPIC"
        value = var.pubsub_topic_name
      }
      env {
        name  = "STATE_PARAMETER_ID"
        value = google_parameter_manager_regional_parameter.state_parameter.name
      }

      # Standard non-sensitive env vars
      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      # SECURE SECRET MOUNTS: The value is never in Terraform or GitHub
      dynamic "env" {
        for_each = var.secret_mounts
        content {
          name = env.key
          value_source {
            secret_key_ref {
              # Use the resource reference for dependency
              secret  = google_secret_manager_secret.mounted_secrets[env.key].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }
}

# IAM: Collector permissions to publish to Pub/Sub
resource "google_pubsub_topic_iam_member" "publisher" {
  project = var.project_id
  topic   = var.pubsub_topic_name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.collector_sa.email}"
}

# IAM: Permission to create service account tokens for delegated auth
resource "google_service_account_iam_member" "collector_token_creator" {
  service_account_id = google_service_account.collector_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.collector_sa.email}"
}

# IAM: Collector permissions to access/manage state in Parameter Manager
resource "google_project_iam_member" "parameter_version_manager" {
  project = var.project_id
  role    = "roles/parametermanager.parameterVersionManager"
  member  = "serviceAccount:${google_service_account.collector_sa.email}"
}

# IAM: Grant access to any secrets being mounted
resource "google_secret_manager_secret_iam_member" "secret_mount_accessor" {
  for_each  = var.secret_mounts
  secret_id = google_secret_manager_secret.mounted_secrets[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector_sa.email}"
}

# Trigger: Cloud Scheduler with OIDC
resource "google_service_account" "scheduler_sa" {
  account_id   = "${var.name}-scheduler-sa"
  display_name = "Service Account to trigger ${var.name} collector"
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  location = google_cloud_run_v2_service.service.location
  name     = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_sa.email}"
}

resource "google_cloud_scheduler_job" "job" {
  name             = "${var.name}-trigger"
  schedule         = var.schedule
  time_zone        = "UTC"
  attempt_deadline = "320s"

  http_target {
    http_method = "POST"
    uri         = google_cloud_run_v2_service.service.uri

    oidc_token {
      service_account_email = google_service_account.scheduler_sa.email
    }
  }
}
