data "google_pubsub_topic" "existing_ingest" {
  name = var.pubsub_topic_name
}

module "collectors" {
  source   = "./modules/collector"
  for_each = { for k, v in var.collectors : k => v if v.enabled }

  project_id        = var.project_id
  region            = var.region
  name              = each.key
  schedule          = each.value.schedule
  pubsub_topic_name = data.google_pubsub_topic.existing_ingest.name
  env_vars          = each.value.env_vars
  secret_mounts     = each.value.secret_mounts
}
