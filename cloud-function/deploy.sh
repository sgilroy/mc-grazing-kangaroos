#!/bin/bash
# Deploy Cloud Function for starting the Minecraft server
#
# Usage: ./deploy.sh

set -e

# Load environment variables
if [ -f ../.env.local ]; then
    export $(grep -v '^#' ../.env.local | xargs)
elif [ -f ../.env ]; then
    export $(grep -v '^#' ../.env | xargs)
fi

PROJECT="${GCP_PROJECT:?Error: GCP_PROJECT not set}"
REGION="${GCP_REGION:-us-east1}"
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-}"

echo "Deploying Cloud Function to $PROJECT in $REGION..."

# Enable required APIs (skip in CI - APIs should be pre-enabled in the project)
if [ -z "$CI" ]; then
    gcloud services enable cloudfunctions.googleapis.com cloudbuild.googleapis.com run.googleapis.com --project "$PROJECT"
else
    echo "Skipping API enablement in CI (APIs should be pre-enabled)"
fi

# Deploy function
gcloud functions deploy mc-start \
    --gen2 \
    --runtime nodejs20 \
    --region "$REGION" \
    --source . \
    --entry-point startServer \
    --trigger-http \
    --allow-unauthenticated \
    --set-env-vars "GCP_PROJECT=$PROJECT,GCP_ZONE=${GCP_ZONE:-us-east1-b},GCP_INSTANCE=${GCP_INSTANCE:-mc},DUCKDNS_DOMAIN=$DUCKDNS_DOMAIN" \
    --project "$PROJECT"

# Grant compute permissions to the function's service account
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/compute.instanceAdmin.v1" \
    --condition=None \
    2>/dev/null || true

FUNCTION_URL="https://${REGION}-${PROJECT}.cloudfunctions.net/mc-start"
echo ""
echo "=== Deployment Complete ==="
echo "Function URL: $FUNCTION_URL"
echo ""
echo "Test with:"
echo "  curl \"$FUNCTION_URL?action=status\""
