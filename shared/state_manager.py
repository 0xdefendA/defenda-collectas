import logging
from typing import Optional

from google.cloud import secretmanager

logger = logging.getLogger(__name__)

class StateManager:
    def __init__(self, project_id: str, secret_id: str):
        self.project_id = project_id
        self.secret_id = secret_id
        self.client = secretmanager.SecretManagerServiceClient()
        self.secret_path = self.client.secret_path(project_id, secret_id)

    def get_state(self) -> Optional[str]:
        """Retrieves the latest state from the Secret Manager.

        Returns:
            The latest state value, or None if not found or on error.
        """
        try:
            # Access the latest version of the secret
            name = f"{self.secret_path}/versions/latest"
            response = self.client.access_secret_version(request={"name": name})
            return response.payload.data.decode("UTF-8")
        except Exception as e:
            logger.warning(f"Could not retrieve state from Secret Manager: {e}")
            return None

    def set_state(self, state_value: str) -> bool:
        """Updates the state by creating a new version of the secret.

        Args:
            state_value: The new state value to store.

        Returns:
            True if successful, False otherwise.
        """
        try:
            # Add a new version to the secret
            payload = state_value.encode("UTF-8")
            self.client.add_secret_version(
                request={"parent": self.secret_path, "payload": {"data": payload}}
            )
            return True
        except Exception as e:
            logger.error(f"Could not update state in Secret Manager: {e}")
            return False
