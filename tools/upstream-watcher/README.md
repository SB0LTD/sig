# upstream-watcher

Polls Codeberg's API for new commits on `zig/zig` master every 30 seconds. When a new commit is detected, fires a `repository_dispatch` event (`upstream-push`) on the sig GitHub repo, which triggers the `sig-sync` workflow.

## Deploy to Cloud Run

```bash
# Build and push
gcloud builds submit --tag gcr.io/PROJECT_ID/upstream-watcher

# Deploy
gcloud run deploy upstream-watcher \
  --image gcr.io/PROJECT_ID/upstream-watcher \
  --region us-central1 \
  --memory 64Mi \
  --cpu 1 \
  --min-instances 1 \
  --max-instances 1 \
  --set-env-vars "GITHUB_TOKEN=ghp_xxx,POLL_INTERVAL=30s" \
  --allow-unauthenticated
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GITHUB_TOKEN` | (required) | GitHub PAT with `repo` scope for dispatching workflows |
| `GITHUB_REPO` | `SB0LTD/sig` | Target repository for dispatch events |
| `POLL_INTERVAL` | `30s` | How often to check Codeberg |
| `PORT` | `8080` | HTTP port (Cloud Run sets this) |

## Cost

~$0/month. Cloud Run free tier covers 2M requests/month. This service makes ~2,600 Codeberg API calls/day (one every 30s) and near-zero GitHub API calls (only on new commits).
