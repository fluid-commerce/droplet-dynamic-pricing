#!/bin/bash
# This script is used to initialize the container on the Compute Engine instance

# A name for the container to run
CONTAINER_NAME="droplet-dynamic-pricing"
IMAGE="europe-west1-docker.pkg.dev/fluid-417204/fluid-droplets/fluid-droplet-dynamic-pricing-rails/web"
TAG="latest"

docker images $IMAGE --format "{{.ID}}" | tail -n +2 | xargs -r docker rmi -f

# Stop and remove the container if it exists
docker stop $CONTAINER_NAME || true
docker rm $CONTAINER_NAME || true

# Pull the latest version of the container image from Docker Hub
docker pull $IMAGE:$TAG

# Run docker container from image in docker hub
docker run \
  --name $CONTAINER_NAME \
  --restart="always" \
  -e "RAILS_ENV=production" \
  -e "DATABASE_URL=postgres://dynamic_pricing_production_user:0O3yxNVWY9Hr3HCB@localhost/fluid_droplet_dynamic_pricing_production?host=10.107.0.33" \
  -e "SECRET_KEY_BASE=99a08e3be2d3c39a118280c24acfdd00" \
  --tty \
  --detach \
  --network="host" \
  $IMAGE:$TAG bash -c "sleep infinity"
