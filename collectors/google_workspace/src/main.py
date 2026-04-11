import json
import logging
import os
import sys
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException
from google.oauth2 import service_account
from googleapiclient.discovery import build
from pydantic import BaseModel

# Add shared directory to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../")))
from shared.pubsub_publisher import PubSubPublisher
from shared.state_manager import StateManager

# Configuration
PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
PUBSUB_TOPIC = os.environ.get("PUBSUB_TOPIC", "defenda-event-ingest")
STATE_SECRET_ID = os.environ.get("STATE_SECRET_ID", "google-workspace-collector-state")
GOOGLE_WORKSPACE_DELEGATED_ACCOUNT = os.environ.get(
    "GOOGLE_WORKSPACE_DELEGATED_ACCOUNT"
)
SCOPES = ["https://www.googleapis.com/auth/admin.reports.audit.readonly"]
APPLICATION_NAMES = os.environ.get(
    "APPLICATION_NAMES", "login,admin,token,drive"
).split(",")

# Setup Logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

# Initialize Shared Utilities
publisher = PubSubPublisher(PROJECT_ID, PUBSUB_TOPIC) if PROJECT_ID else None
state_manager = StateManager(PROJECT_ID, STATE_SECRET_ID) if PROJECT_ID else None


class TriggerResponse(BaseModel):
    status: str
    message: str
    records_processed: int


def get_google_credentials():
    """Retrieves Google service account credentials and delegates to a user."""
    # This assumes GOOGLE_APPLICATION_CREDENTIALS points to a JSON file
    # or the service account is already authenticated.
    # For delegation, we need the service account key.
    creds_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not creds_path:
        logger.error("GOOGLE_APPLICATION_CREDENTIALS environment variable not set.")
        return None

    creds = service_account.Credentials.from_service_account_file(
        creds_path, scopes=SCOPES
    )
    if GOOGLE_WORKSPACE_DELEGATED_ACCOUNT:
        creds = creds.with_subject(GOOGLE_WORKSPACE_DELEGATED_ACCOUNT)
    return creds


@app.post("/", response_model=TriggerResponse)
async def trigger_collection():
    """Trigger point for Cloud Scheduler."""
    if not PROJECT_ID:
        raise HTTPException(status_code=500, detail="GCP_PROJECT_ID not configured")

    logger.info("Starting Google Workspace log collection...")

    creds = get_google_credentials()
    if not creds:
        raise HTTPException(
            status_code=500, detail="Failed to obtain Google credentials"
        )

    service = build("admin", "reports_v1", credentials=creds, cache_discovery=False)

    # Get state (last query time)
    last_query_time_str = state_manager.get_state()
    if not last_query_time_str:
        # Default to 1 hour ago if no state exists
        last_query_time = datetime.now(timezone.utc) - timedelta(hours=1)
        last_query_time_str = last_query_time.isoformat()

    logger.info(f"Fetching logs since: {last_query_time_str}")

    total_records = 0
    current_run_time = datetime.now(timezone.utc).isoformat()

    for app_name in APPLICATION_NAMES:
        logger.info(f"Processing application: {app_name}")
        page_token = None
        while True:
            try:
                results = (
                    service.activities()
                    .list(
                        userKey="all",
                        applicationName=app_name.strip(),
                        startTime=last_query_time_str,
                        pageToken=page_token,
                        maxResults=1000,
                    )
                    .execute()
                )
            except Exception as e:
                logger.error(f"Error fetching logs for {app_name}: {e}")
                break

            records = results.get("items", [])
            if records:
                logger.info(f"Retrieved {len(records)} records for {app_name}")
                # Enrich records with source info if needed
                for record in records:
                    record["_collector_source"] = "google_workspace"
                    record["_collector_app"] = app_name

                published_count = publisher.publish_messages(records)
                total_records += published_count
                logger.info(f"Published {published_count} records to Pub/Sub")

            page_token = results.get("nextPageToken")
            if not page_token:
                break

    # Update state only if we processed records or if we want to move forward anyway
    # The old logic only moved forward if records were retrieved.
    if total_records > 0:
        state_manager.set_state(current_run_time)
        logger.info(f"Updated state to: {current_run_time}")

    return TriggerResponse(
        status="success",
        message=f"Completed collection for {len(APPLICATION_NAMES)} apps",
        records_processed=total_records,
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
