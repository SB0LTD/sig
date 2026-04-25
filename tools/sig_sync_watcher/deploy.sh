#!/bin/bash
set -euo pipefail

# Sig Sync Watcher — GCP Cloud Run deployment
#
# The watcher is compiled by the sig bootstrap compiler (v9+, dev=.full).
# The bootstrap downloads its own std lib, so we only need main.sig.
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

TMPCTX=$(mktemp -d)
trap "rm -rf $TMPCTX" EXIT

cp tools/sig_sync_watcher/main.sig "$TMPCTX/main.sig"

# Inline Dockerfile — downloads bootstrap sig and compiles the watcher
cat > "$TMPCTX/Dockerfile" << 'DOCKERFILE'
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Download bootstrap-sig-v10 (dev=.full, supports build-exe)
RUN curl -sL "https://github.com/SB0LTD/sig/releases/download/bootstrap-sig-v10/bootstrap-sig-x86_64-linux.tar.gz" \
    | tar -xz -C /opt && \
    chmod +x /opt/bin/sig /opt/bin/zig && \
    echo "sig bootstrap ready"

# Clone just the lib/ directory we need for compilation
RUN curl -sL "https://github.com/SB0LTD/sig/archive/refs/heads/master.tar.gz" \
    | tar -xz --strip-components=1 -C /opt/sig-src "sig-master/lib" && \
    echo "std lib ready"

WORKDIR /app
COPY main.sig main.sig

RUN /opt/bin/sig build-exe main.sig \
    --zig-lib-dir /opt/sig-src/lib \
    -target x86_64-linux-musl -OReleaseSafe \
    --name sig-sync-watcher

FROM alpine:3.21
RUN apk add --no-cache curl ca-certificates
COPY --from=builder /app/sig-sync-watcher /sig-sync-watcher
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/sig-sync-watcher"]
DOCKERFILE

echo "    Context size: $(du -sh "$TMPCTX" | cut -f1)"

# ── Build with Cloud Build ────────────────────────────────────────────
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
