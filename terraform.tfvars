collectors = {
  google-workspace = {
    enabled  = true
    schedule = "0 * * * *" # Hourly
    env_vars = {
      "APPLICATION_NAMES" = "login,admin,token,drive"
    }
    secret_mounts = {
      # This points to a secret ID in Secret Manager, NOT the literal email value
      "GOOGLE_WORKSPACE_DELEGATED_ACCOUNT" = "google-workspace-admin-email"
    }
  }
}
