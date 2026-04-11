import json
import logging
from typing import Any, Dict, List

from google.cloud import pubsub_v1

logger = logging.getLogger(__name__)

class PubSubPublisher:
    def __init__(self, project_id: str, topic_id: str):
        self.project_id = project_id
        self.topic_id = topic_id
        self.publisher = pubsub_v1.PublisherClient()
        self.topic_path = self.publisher.topic_path(project_id, topic_id)

    def publish_messages(self, messages: List[Dict[str, Any]]) -> int:
        """Publishes multiple messages to the Pub/Sub topic.

        Args:
            messages: A list of dictionaries representing the messages to publish.

        Returns:
            The number of successfully published messages.
        """
        count = 0
        futures = []

        for msg in messages:
            data = json.dumps(msg).encode("utf-8")
            future = self.publisher.publish(self.topic_path, data)
            futures.append(future)

        for future in futures:
            try:
                future.result()
                count += 1
            except Exception as e:
                logger.error(f"Failed to publish message: {e}")

        return count

    def publish_message(self, message: Dict[str, Any]) -> bool:
        """Publishes a single message to the Pub/Sub topic.

        Args:
            message: A dictionary representing the message to publish.

        Returns:
            True if the message was successfully published, False otherwise.
        """
        data = json.dumps(message).encode("utf-8")
        future = self.publisher.publish(self.topic_path, data)
        try:
            future.result()
            return True
        except Exception as e:
            logger.error(f"Failed to publish message: {e}")
            return False
