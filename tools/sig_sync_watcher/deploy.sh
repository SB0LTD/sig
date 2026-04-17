#!/bin/bash
set -euo pipefail

# Sig Sync Watcher — GCP Cloud Run deployment
#
# Builds a minimal Docker context (only the files the Dockerfile needs),
# pushes to Artifact Registry, and deploys to Cloud Run with Cloud Scheduler.
#
# Prerequisites:
#   - gcloud CLI authenticated
#   - GCP project with Cloud Run, Cloud Scheduler, Secret Manager, Artifact Registry APIs enabled
#   - Service account: sig-sync-watcher@{PROJECT}.iam.gserviceaccount.com
#   - Secret: sig-sync-github-token in Secret Manager
#   - Artifact Registry repo: us-central1-docker.pkg.dev/{PROJECT}/sig
#
# Usage:
#   ./tools/sig_sync_watcher/deploy.sh [PROJECT_ID] [REGION]
#   (run from sig repo root)

PROJECT_ID="${1:-sbzero}"
REGION="${2:-us-central1}"
SERVICE_NAME="sig-sync-watcher"
SA_EMAIL="sig-sync-watcher@${PROJECT_ID}.iam.gserviceaccount.com"
GITHUB_REPO="SB0LTD/sig"
SCHEDULER_JOB="sig-sync-poll"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/sig/${SERVICE_NAME}"

echo "==> Preparing minimal build context"

# Create a temp directory with only the files the Dockerfile needs
TMPCTX=$(mktemp -d)
trap "rm -rf $TMPCTX" EXIT

cp tools/sig_sync_watcher/Dockerfile "$TMPCTX/Dockerfile"
cp tools/sig_sync_watcher/main.sig   "$TMPCTX/main.sig"

# Rewrite Dockerfile for flat context (no nested paths)
# Use the repo's Dockerfile directly
cp tools/sig_sync_watcher/Dockerfile "$TMPCTX/Dockerfile"

echo "    Context size: $(du -sh "$TMPCTX" | cut -f1)"

# ── Ensure Artifact Registry repo exists ──────────────────────────────
gcloud artifacts repositories describe sig \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --format="value(name)" 2>/dev/null || \
gcloud artifacts repositories create sig \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --repository-format=docker \
  --description="Sig container images" \
  --quiet

# ── Build with Cloud Build (tiny context, fast upload) ────────────────
echo "==> Building image via Cloud Build"
gcloud builds submit "$TMPCTX" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --tag="$IMAGE:latest" \
  --quiet

# ── Deploy to Cloud Run ──────────────────────────────────────────────
echo "==> Deploying to Cloud Run"
gcloud run deploy "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --image="$IMAGE:latest" \
  --platform=managed \
  --no-allow-unauthenticated \
  --service-account="$SA_EMAIL" \
  --memory=128Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=1 \
  --timeout=30s \
  --set-env-vars="GITHUB_REPO=$GITHUB_REPO" \
  --set-secrets="GITHUB_TOKEN=sig-sync-github-token:latest" \
  --quiet

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format="value(status.url)")

echo "==> Service deployed at: $SERVICE_URL"

# ── Cloud Scheduler (2 jobs offset by 30s → ~30s polling) ────────────
echo "==> Setting up Cloud Scheduler"

for OFFSET in 0 30; do
  JOB_NAME="${SCHEDULER_JOB}-${OFFSET}s"

  gcloud scheduler jobs delete "$JOB_NAME" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --quiet 2>/dev/null || true

  gcloud scheduler jobs create http "$JOB_NAME" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --schedule="* * * * *" \
    --uri="${SERVICE_URL}/check" \
    --http-method=GET \
    --oidc-service-account-email="$SA_EMAIL" \
    --oidc-token-audience="$SERVICE_URL" \
    --attempt-deadline=30s \
    --quiet

  echo "  Created: $JOB_NAME"
done

echo ""
echo "==> Deployment complete!"
echo "    Service:   $SERVICE_URL"
echo "    Polling:   Every ~30 seconds (2 scheduler jobs)"
echo "    RSS feed:  https://codeberg.org/ziglang/zig/rss/branch/master"
echo "    Dispatch:  https://api.github.com/repos/$GITHUB_REPO/dispatches"
