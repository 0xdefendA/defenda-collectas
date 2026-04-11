resource "google_service_account" "collector_sa" {
  account_id   = "${var.name}-collector-sa"
  display_name = "Service Account for ${var.name} collector"
}

resource "google_secret_manager_secret" "state_secret" {
  secret_id = "${var.name}-collector-state"
  replication {
    auto {}
  }
}

resource "google_cloud_run_v2_service" "service" {
  name     = "${var.name}-collector"
  location = var.region
  # Using INGRESS_TRAFFIC_INTERNAL_ONLY for security if only triggered by Scheduler
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.collector_sa.email
    containers {
      image = var.image
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
        name  = "STATE_SECRET_ID"
        value = google_secret_manager_secret.state_secret.secret_id
      }

      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env_vars
        content {
          name  = env.key
          value = env.value
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

# IAM: Collector permissions to access/manage state in Secret Manager
resource "google_secret_manager_secret_iam_member" "state_accessor" {
  secret_id = google_secret_manager_secret.state_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.collector_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "state_version_manager" {
  secret_id = google_secret_manager_secret.state_secret.id
  role      = "roles/secretmanager.secretVersionManager"
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
