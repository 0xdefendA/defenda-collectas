# Google Workspace Collector

This service collects activity logs from Google Workspace using the Google Admin SDK Reports API and publishes them to a GCP Pub/Sub topic.

## Local Development

### Prerequisites

- Docker and Docker Compose
- Google Cloud Service Account with:
    - `roles/pubsub.publisher`
    - `roles/secretmanager.admin` (or `roles/secretmanager.secretAccessor` and `roles/secretmanager.secretVersionManager`)
    - Domain-wide delegation enabled for the Admin SDK.

### Setup

1.  Place your service account JSON key in this directory as `credentials.json`.
2.  Set the following environment variables in your shell or a `.env` file:
    - `GCP_PROJECT_ID`: Your GCP project ID.
    - `GOOGLE_WORKSPACE_DELEGATED_ACCOUNT`: The email of the Google Workspace admin user to impersonate.
    - `GOOGLE_APPLICATION_CREDENTIALS`: `/app/collectors/google_workspace/credentials.json` (inside the container).

### Running with Docker Compose

From the root of the monorepo:

```bash
docker-compose up --build
```

This will start the Google Workspace collector and a local Pub/Sub emulator.

### Triggering a Collection Run

The collector exposes a POST endpoint at `/`. You can trigger it using `curl`:

```bash
curl -X POST http://localhost:8080/
```

## Configuration

The following environment variables can be used to configure the service:

| Variable | Description | Default |
| --- | --- | --- |
| `GCP_PROJECT_ID` | GCP Project ID | |
| `PUBSUB_TOPIC` | Pub/Sub topic to publish logs to | `google-workspace-events` |
| `STATE_SECRET_ID` | Secret ID in Secret Manager to store the last run time | `google-workspace-collector-state` |
| `GOOGLE_WORKSPACE_DELEGATED_ACCOUNT` | Admin user email for domain-wide delegation | |
| `APPLICATION_NAMES` | Comma-separated list of apps to collect (e.g., `login,admin,drive`) | `login,admin,token,drive` |
| `PORT` | Port for the FastAPI server | `8080` |
