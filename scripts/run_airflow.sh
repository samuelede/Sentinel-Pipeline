#!/usr/bin/env bash
#
# Builds and runs Airflow via Docker in one command, using
# docker-compose.airflow.yml. This sidesteps Airflow's lack of native
# Windows support entirely, everything runs inside a Linux container.
#
# Usage:
#   ./scripts/run_airflow.sh
#
# Requires Docker Desktop installed and running. Requires .env to exist
# with the pipeline's normal values filled in, see docs/SETUP_CHECKLIST.md.

set -e

if [ ! -f .env ]; then
  echo "No .env file found. Run 'cp .env.example .env' and fill in required values first."
  echo "See docs/SETUP_CHECKLIST.md."
  exit 1
fi

if ! command -v docker > /dev/null 2>&1; then
  echo "Docker not found. Install Docker Desktop first: https://www.docker.com/products/docker-desktop/"
  exit 1
fi

if ! docker info > /dev/null 2>&1; then
  echo "Docker is installed but not running. Start Docker Desktop, wait for it to finish starting, then re-run this script."
  exit 1
fi

echo "== Building the Airflow image (first run takes a few minutes) =="
docker compose -f docker-compose.airflow.yml build

echo ""
echo "== Starting Airflow (webserver + scheduler, via 'airflow standalone') =="
echo "This will run in the foreground. Press Ctrl+C to stop it."
echo ""
echo "Once it's up:"
echo "  - Web UI: http://localhost:8080"
echo "  - Username: admin"
echo "  - Password: printed below once standalone finishes initializing (look for 'Password for user admin:')"
echo ""

docker compose -f docker-compose.airflow.yml up
