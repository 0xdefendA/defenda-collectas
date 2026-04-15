import logging
import os
import sys
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI, HTTPException
from google.oauth2 import service_account
from googleapiclient.discovery import build
from pydantic import BaseModel
import google.auth

# Add shared directory to path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../")))
from shared.pubsub_publisher import PubSubPublisher
from shared.state_manager import StateManager

# Configuration
credentials, PROJECT_ID = google.auth.default()
PUBSUB_TOPIC = os.environ.get("PUBSUB_TOPIC", "defenda-event-ingest")
STATE_PARAMETER_ID = os.environ.get(
    "STATE_PARAMETER_ID", "google-workspace-collector-state"
)
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
state_manager = StateManager(PROJECT_ID, STATE_PARAMETER_ID) if PROJECT_ID else None


class TriggerResponse(BaseModel):
    status: str
    message: str
    records_processed: int


def delegated_credential(credentials, subject, scopes):
    from google.auth import iam
    from google.auth.transport import requests
    from google.oauth2 import service_account

    TOKEN_URI = "https://accounts.google.com/o/oauth2/token"
    try:
        admin_creds = credentials.with_subject(subject).with_scopes(scopes)
    except AttributeError:  # Looks like a compute creds object
        # Refresh the boostrap credentials. This ensures that the information
        # about this account, notably the email, is populated.
        request = requests.Request()
        credentials.refresh(request)

        # Create an IAM signer using the bootstrap credentials.
        signer = iam.Signer(request, credentials, credentials.service_account_email)

        # Create OAuth 2.0 Service Account credentials using the IAM-based
        # signer and the bootstrap_credential's service account email.
        admin_creds = service_account.Credentials(
            signer,
            credentials.service_account_email,
            TOKEN_URI,
            scopes=scopes,
            subject=subject,
        )
    except Exception:
        raise

    return admin_creds


@app.post("/", response_model=TriggerResponse)
async def trigger_collection():
    """Trigger point for Cloud Scheduler."""
    if not PROJECT_ID:
        raise HTTPException(status_code=500, detail="GCP_PROJECT_ID not configured")

    logger.info("Starting Google Workspace log collection...")

    service_creds = delegated_credential(
        credentials, GOOGLE_WORKSPACE_DELEGATED_ACCOUNT, SCOPES
    )
    if not service_creds:
        raise HTTPException(
            status_code=500, detail="Failed to obtain Delegated credentials"
        )

    service = build(
        "admin", "reports_v1", credentials=service_creds, cache_discovery=False
    )

    # Get state (last query time)
    last_query_time_str = state_manager.get_state()
    if not last_query_time_str:
        # Default to 1 hour ago if no state exists
        last_query_time = datetime.now(timezone.utc) - timedelta(hours=1)
        last_query_time_str = last_query_time.isoformat()

    # gmail requires an end time, so we set it to now + 1 hour to ensure we capture all recent logs up to the current time.
    end_time = datetime.now(timezone.utc) + timedelta(hours=1)
    end_time_str = end_time.isoformat()

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
                        endTime=end_time_str,
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
