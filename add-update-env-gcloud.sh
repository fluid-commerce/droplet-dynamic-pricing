#!/bin/bash

# Application name
APP_NAME=fluid-droplet-dynamic-pricing

# Service names
SERVICE=$APP_NAME
SERVICE_JOBS_MIGRATIONS=$APP_NAME-migrations
SERVICE_SOLIDQUEUE=$APP_NAME-solidqueue
IMAGE_URL=europe-west1-docker.pkg.dev/fluid-417204/fluid-droplets/$APP_NAME-rails/web:latest

# Variables array - add your variables here
VARS=(
  "ENV_EXAMPLE=value"
  # Add more variables as needed
)

# Build the environment variables arguments for Cloud Run
CLOUD_RUN_ENV_ARGS=""
for var in "${VARS[@]}"; do
  CLOUD_RUN_ENV_ARGS="$CLOUD_RUN_ENV_ARGS --update-env-vars $var"
done

# Update the environment variables for the service cloud run web Cloud Run migrations
gcloud run jobs update $SERVICE_JOBS_MIGRATIONS --region=europe-west1 --image $IMAGE_URL $CLOUD_RUN_ENV_ARGS

# Update the environment variables for the service cloud run web
echo "Updating Cloud Run service: $SERVICE"
gcloud run services update $SERVICE --region=europe-west1 --image $IMAGE_URL $CLOUD_RUN_ENV_ARGS

# Update the environment variables for the service cloud run solidqueue
echo "Updating Cloud Run worker pool: $SERVICE_SOLIDQUEUE"
gcloud beta run worker-pools update $SERVICE_SOLIDQUEUE --region=europe-west1 --image $IMAGE_URL $CLOUD_RUN_ENV_ARGS