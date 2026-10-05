# FlareSolverr — Standalone App Design

**Date:** 2026-05-21
**Status:** Approved

## Purpose

Run [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) as a standalone, internal-only service in the homelab cluster so other apps can route HTTP requests through it when they hit Cloudflare anti-bot challenges. Initial consumer: `scraper-backend` in the `pokemon-bot` namespace.

## Scope

In scope:
- New Helm template under `apps/templates/app-flaresolverr.yaml` deploying FlareSolverr in its own namespace.
- One env var addition (`FLARESOLVERR_URL`) to the `scraper-backend` Deployment in `apps/templates/app-pokemon-bot.yaml`.

Out of scope:
- Modifying the pokemon-bot application code to actually call FlareSolverr. That lives in a separate repo and is covered by a companion prompt handed to the user.
- Touching `cavempt-scraper` (`app-scraper.yaml`). Explicitly excluded per user direction.
- Exposing FlareSolverr externally (no Tailscale or Cloudflare-tunnel Ingress).
- Persistence. FlareSolverr keeps sessions in memory; no PVC is needed.

## Architecture

```
┌────────────────────────────┐         ┌────────────────────────────┐
│ namespace: pokemon-bot     │         │ namespace: flaresolverr    │
│                            │         │                            │
│  scraper-backend  ─────────┼────────►│  flaresolverr (Deployment) │
│  (env: FLARESOLVERR_URL)   │  HTTP   │  Service ClusterIP :8191   │
│                            │  8191   │                            │
└────────────────────────────┘         └────────────────────────────┘
```

Cross-namespace traffic flows via cluster DNS:
`http://flaresolverr.flaresolverr.svc.cluster.local:8191`.

There is no NetworkPolicy in this cluster, so no additional policy resource is required.

## Components

### `apps/templates/app-flaresolverr.yaml` (new)

A single Helm template containing three resources:

1. **Namespace** `flaresolverr` with the standard `name: flaresolverr` label, matching the convention of other apps in this repo.
2. **Deployment** `flaresolverr` in the `flaresolverr` namespace:
   - `replicas: 1`
   - Container `flaresolverr` running `ghcr.io/flaresolverr/flaresolverr:latest`
   - `containerPort: 8191`
   - Env:
     - `LOG_LEVEL=info`
     - `TZ=Europe/Amsterdam`
   - Resources:
     - requests: `cpu: 200m`, `memory: 512Mi`
     - limits: `cpu: 1000m`, `memory: 1Gi`
   - No volume mounts. No imagePullSecret (image is on public GHCR).
3. **Service** `flaresolverr` in the `flaresolverr` namespace:
   - `type: ClusterIP`
   - Selector `app: flaresolverr`
   - Port `8191` → targetPort `8191`

No Secret, Ingress, PVC, CronJob, or RBAC objects are added.

### `apps/templates/app-pokemon-bot.yaml` (modified)

In the `scraper-backend` Deployment's container `env:` list, append:

```yaml
- name: FLARESOLVERR_URL
  value: http://flaresolverr.flaresolverr.svc.cluster.local:8191
```

No other deployment (notifications-backend, checkout-backend, dashboard-backend, scraper-/notifications-/checkout-/dashboard-frontend, rabbitmq, db-init) is touched.

## Data Flow

1. `scraper-backend` reads `FLARESOLVERR_URL` from its environment on startup.
2. When the application code (separate repo) determines a target site is Cloudflare-gated, it POSTs a `request.get` payload to `${FLARESOLVERR_URL}/v1`.
3. FlareSolverr launches/reuses a headless Chromium session, completes the challenge, and returns the resolved HTML + cookies as JSON.
4. `scraper-backend` uses the returned cookies/HTML for downstream processing.

## Error Handling

- **FlareSolverr pod down or starting:** scraper-backend's HTTP call fails fast at the service level. Behavior on the scraper side (retry, fall back to direct request, mark failure) is decided by the application code, not by this manifest.
- **Memory pressure:** Chromium can grow over time. The `1Gi` limit will cause the container to OOMKill rather than starve the node; kubelet restarts it. Sessions are lost on restart, which is acceptable — FlareSolverr is designed to be recoverable.
- **Image pull issues:** Public GHCR image; no auth required. ArgoCD will mark the Application degraded until the pull recovers.

## Testing / Verification

This repo has no test suite; verification is operational:

1. After ArgoCD syncs, confirm the `flaresolverr` namespace exists and the Deployment is `1/1 Ready`.
2. From inside the cluster (e.g., `kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- sh`), hit:
   ```
   curl http://flaresolverr.flaresolverr.svc.cluster.local:8191/
   ```
   Expect a JSON response with FlareSolverr version info.
3. Confirm `scraper-backend` pod has `FLARESOLVERR_URL` set in its env (`kubectl -n pokemon-bot exec deploy/scraper-backend -- printenv FLARESOLVERR_URL`).

## Companion Work (handed off, not in this repo)

The pokemon-bot application repo needs separate code changes to read `FLARESOLVERR_URL` and route Cloudflare-gated requests through it. A standalone prompt for that work is delivered alongside this spec.

## Rollback

`git revert` the merge. ArgoCD will prune the `flaresolverr` namespace and remove the env var from `scraper-backend`. With no callers yet wired up on the application side, this is a no-op rollback.
