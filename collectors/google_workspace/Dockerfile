# Use the official lightweight Python image.
# https://hub.docker.com/_/python
FROM python:3.12-slim

# Allow statements and log messages to immediately appear in the Knative logs
ENV PYTHONUNBUFFERED True

# Copy local code to the container image.
ENV APP_HOME /app
WORKDIR $APP_HOME

# Copy shared utilities
COPY shared ./shared

# Copy collector-specific code
COPY collectors/google_workspace ./collectors/google_workspace

# Install dependencies
RUN pip install --no-cache-dir -r collectors/google_workspace/requirements.txt

# Set the entry point to run the FastAPI app
CMD ["python", "collectors/google_workspace/src/main.py"]
