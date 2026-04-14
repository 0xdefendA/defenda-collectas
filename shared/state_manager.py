import logging
from typing import Optional

from google.cloud import parametermanager_v1

logger = logging.getLogger(__name__)


class StateManager:
    def __init__(
        self, project_id: str, parameter_id: str, location_id: str = "us-central1"
    ):
        self.project_id = project_id
        self.parameter_id = parameter_id
        self.location_id = location_id

        # Create the Parameter Manager client with the regional endpoint.
        api_endpoint = f"parametermanager.{location_id}.rep.googleapis.com"
        self.client = parametermanager_v1.ParameterManagerClient(
            client_options={"api_endpoint": api_endpoint}
        )
        self.parameter_path = self.client.parameter_path(
            project_id, location_id, parameter_id
        )

    def get_state(self) -> Optional[str]:
        """Retrieves the latest state from the Parameter Manager.

        Returns:
            The latest state value, or None if not found or on error.
        """
        try:
            # List versions and find the one with the most recent create_time
            request = parametermanager_v1.ListParameterVersionsRequest(
                parent=self.parameter_path,
                page_size=1,
                order_by="create_time desc",
            )
            results = self.client.list_parameter_versions(request=request)
            versions = list(results)
            if not versions:
                return None

            latest_version = versions[0]

            # Get the full version details including payload
            get_request = parametermanager_v1.GetParameterVersionRequest(
                name=latest_version.name
            )
            response = self.client.get_parameter_version(request=get_request)

            if response.disabled:
                logger.warning(f"Parameter version {response.name} is disabled")
                return None

            return response.payload.data.decode("UTF-8")
        except Exception as e:
            logger.warning(f"Could not retrieve state from Parameter Manager: {e}")
            return None

    def set_state(self, state_value: str) -> bool:
        """Updates the state by creating a new version of the parameter.

        Args:
            state_value: The new state value to store.

        Returns:
            True if successful, False otherwise.
        """
        try:
            import time

            # Generate a unique version ID based on current timestamp
            version_id = f"v{int(time.time())}"

            request = parametermanager_v1.CreateParameterVersionRequest(
                parent=self.parameter_path,
                parameter_version_id=version_id,
                parameter_version=parametermanager_v1.ParameterVersion(
                    payload=parametermanager_v1.ParameterVersionPayload(
                        data=state_value.encode("UTF-8")
                    )
                ),
            )
            self.client.create_parameter_version(request=request)
            return True
        except Exception as e:
            logger.error(f"Could not update state in Parameter Manager: {e}")
            return False
