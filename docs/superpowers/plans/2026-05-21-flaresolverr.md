# FlareSolverr Standalone App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) as an internal-only Kubernetes service in this homelab cluster and expose its URL to `scraper-backend` in the `pokemon-bot` namespace via an env var.

**Architecture:** Single new Helm template at `apps/templates/app-flaresolverr.yaml` defining a `Namespace`, `Deployment` (1 replica, headless Chromium-based service on port 8191), and ClusterIP `Service`. One edit to `apps/templates/app-pokemon-bot.yaml` adds `FLARESOLVERR_URL=http://flaresolverr.flaresolverr.svc.cluster.local:8191` to the `scraper-backend` Deployment. ArgoCD picks both up from the `apps/` chart.

**Tech Stack:** Helm, Kubernetes, ArgoCD (GitOps), SOPS-encrypted Helm values (`apps/secrets.yaml`).

**Context for the engineer:**
- This repo is a single Helm chart at `apps/` whose templates each describe one logical app. ArgoCD watches the chart (see `app.yaml` at the repo root) and applies changes on every commit to `main`.
- Secrets live in `apps/secrets.yaml` (encrypted) and `apps/secrets.yaml.dec` (decrypted local copy used for `helm template` validation). FlareSolverr needs no secret values.
- There is no test framework. Validation = local `helm template` rendering + post-deploy `kubectl` smoke checks. Take both seriously.
- Companion design spec: `docs/superpowers/specs/2026-05-21-flaresolverr-design.md`.

---

## Task 1: Add the FlareSolverr manifest

**Files:**
- Create: `apps/templates/app-flaresolverr.yaml`

- [ ] **Step 1: Create the manifest file**

Write the following content to `apps/templates/app-flaresolverr.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: flaresolverr
  labels:
    name: flaresolverr
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flaresolverr
  namespace: flaresolverr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flaresolverr
  template:
    metadata:
      labels:
        app: flaresolverr
    spec:
      containers:
        - name: flaresolverr
          image: ghcr.io/flaresolverr/flaresolverr:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8191
          env:
            - name: LOG_LEVEL
              value: info
            - name: TZ
              value: Europe/Amsterdam
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: flaresolverr
  namespace: flaresolverr
spec:
  type: ClusterIP
  selector:
    app: flaresolverr
  ports:
    - name: http
      port: 8191
      targetPort: 8191
```

Notes for the engineer:
- The image is on public GHCR. No `imagePullSecrets` block is needed (every other app in this repo that pulls from a private registry sets one explicitly; this one doesn't need to).
- `replicas: 1` is intentional. FlareSolverr keeps browser sessions in memory; running multiple replicas would split sessions across pods unpredictably.
- The Service is intentionally unnamed in DNS terms beyond its default `<service>.<namespace>.svc.cluster.local` — that's the address Task 2 will reference.

- [ ] **Step 2: Validate the template renders**

Run from the repo root:

```bash
helm template apps -f apps/secrets.yaml.dec --show-only templates/app-flaresolverr.yaml
```

Expected: clean YAML output containing the Namespace, Deployment, and Service in that order. No errors. Helm-secrets plugin warnings on stderr are fine and unrelated.

If you get `Error: open apps/secrets.yaml.dec: no such file or directory`, ask the user — `secrets.yaml.dec` is the local SOPS-decrypted copy and must already exist (it's gitignored).

- [ ] **Step 3: Validate the rendered YAML is well-formed Kubernetes**

Run:

```bash
helm template apps -f apps/secrets.yaml.dec --show-only templates/app-flaresolverr.yaml | kubectl apply --dry-run=client -f -
```

Expected output: three lines, one per resource:

```
namespace/flaresolverr created (dry run)
deployment.apps/flaresolverr created (dry run)
service/flaresolverr created (dry run)
```

If any resource is missing or you get a schema error, fix the manifest and re-run Step 2 + Step 3 before proceeding.

- [ ] **Step 4: Commit**

```bash
git add apps/templates/app-flaresolverr.yaml
git commit -m "feat(flaresolverr): add standalone Cloudflare-solver service"
```

---

## Task 2: Wire FLARESOLVERR_URL into pokemon-bot scraper-backend

**Files:**
- Modify: `apps/templates/app-pokemon-bot.yaml` (the `scraper-backend` Deployment's container `env:` list)

- [ ] **Step 1: Identify the exact edit location**

Open `apps/templates/app-pokemon-bot.yaml` and find the `scraper-backend` Deployment. It begins around line 266 (`name: scraper-backend`). Its container's `env:` list currently ends with the `SPRING_RABBITMQ_PASSWORD` entry, which in the current file is at approximately line 306. The container's `resources:` block immediately follows.

Confirm by grepping:

```bash
grep -n "SPRING_RABBITMQ_PASSWORD" apps/templates/app-pokemon-bot.yaml
```

You should see at least three matches (scraper-backend, notifications-backend, checkout-backend). You want the **first** one — the scraper-backend's.

- [ ] **Step 2: Add the env var**

In `apps/templates/app-pokemon-bot.yaml`, in the `scraper-backend` Deployment only, append one entry to the container's `env:` list, immediately after the existing `SPRING_RABBITMQ_PASSWORD` entry and before `resources:`.

The existing block (in the scraper-backend section) looks like this:

```yaml
            - name: SPRING_RABBITMQ_PASSWORD
              value: guest
          resources:
            requests:
              cpu: 200m
```

Change it to:

```yaml
            - name: SPRING_RABBITMQ_PASSWORD
              value: guest
            - name: FLARESOLVERR_URL
              value: http://flaresolverr.flaresolverr.svc.cluster.local:8191
          resources:
            requests:
              cpu: 200m
```

**Important:** do this edit only for the `scraper-backend` Deployment. The `notifications-backend` and `checkout-backend` deployments have an identical-looking `SPRING_RABBITMQ_PASSWORD` line; do not touch those. The safest approach is to use a sufficiently-large `old_string` that includes a few lines above (e.g. `SPRING_RABBITMQ_HOST: rabbitmq.pokemon-bot.svc.cluster.local`) and the scraper-backend's specific `cpu: 200m` line, so the match is unique to the scraper-backend section.

- [ ] **Step 3: Validate the rendered Deployment includes the new env var**

Run:

```bash
helm template apps -f apps/secrets.yaml.dec --show-only templates/app-pokemon-bot.yaml | \
  awk '/name: scraper-backend$/,/^---$/' | \
  grep -A1 FLARESOLVERR_URL
```

Expected output:

```
            - name: FLARESOLVERR_URL
              value: http://flaresolverr.flaresolverr.svc.cluster.local:8191
```

If grep returns nothing, your edit didn't land in the right Deployment; re-check Step 1's location.

- [ ] **Step 4: Confirm no other deployment was modified**

Run:

```bash
helm template apps -f apps/secrets.yaml.dec --show-only templates/app-pokemon-bot.yaml | \
  grep -c FLARESOLVERR_URL
```

Expected: `2` (one `name:` line, one `value:` line — both inside the scraper-backend container). If you get `4` or higher, you edited more than one deployment by mistake.

- [ ] **Step 5: Dry-run the full chart**

```bash
helm template apps -f apps/secrets.yaml.dec | kubectl apply --dry-run=client -f - > /dev/null
```

Expected: command exits 0 with no errors. (Output is discarded because we just care about the validation step.)

- [ ] **Step 6: Commit**

```bash
git add apps/templates/app-pokemon-bot.yaml
git commit -m "feat(pokemon-bot): inject FLARESOLVERR_URL into scraper-backend"
```

---

## Task 3: Post-deploy verification (after ArgoCD syncs)

**Files:** none (operational verification)

This task runs against the live cluster *after* the two commits from Tasks 1 and 2 reach `main` and ArgoCD reconciles. If ArgoCD's auto-sync is on (it is, per `app.yaml`), this happens automatically within a minute or two. Otherwise trigger a manual sync from the ArgoCD UI.

- [ ] **Step 1: Confirm the FlareSolverr namespace and pod are Ready**

```bash
kubectl get ns flaresolverr
kubectl -n flaresolverr get deploy flaresolverr
kubectl -n flaresolverr get pods
```

Expected:
- Namespace `flaresolverr` exists, status `Active`.
- Deployment shows `1/1` ready.
- Pod is `Running` and `1/1` ready.

If the pod is `CrashLoopBackOff` or `ImagePullBackOff`, run `kubectl -n flaresolverr describe pod <pod>` and address the issue (most likely cause: image tag drift on `:latest`; if so, pin to a specific version like `:v3.3.21` and re-commit).

- [ ] **Step 2: Curl FlareSolverr from inside the cluster**

```bash
kubectl run -it --rm flaresolverr-test \
  --image=curlimages/curl --restart=Never -- \
  curl -sS http://flaresolverr.flaresolverr.svc.cluster.local:8191/
```

Expected: a JSON body resembling:

```json
{"msg":"FlareSolverr is ready!","version":"...","userAgent":"..."}
```

The pod self-deletes when the command exits.

- [ ] **Step 3: Confirm FLARESOLVERR_URL is set on scraper-backend**

```bash
kubectl -n pokemon-bot exec deploy/scraper-backend -- printenv FLARESOLVERR_URL
```

Expected exact output:

```
http://flaresolverr.flaresolverr.svc.cluster.local:8191
```

If the command returns nothing or errors with `printenv: FLARESOLVERR_URL: No such file or directory`, ArgoCD may not have rolled the new pod template yet. Check:

```bash
kubectl -n pokemon-bot rollout status deploy/scraper-backend
```

and re-run when ready.

- [ ] **Step 4: Exercise FlareSolverr with a real challenge (optional smoke test)**

```bash
kubectl run -it --rm flaresolverr-real-test \
  --image=curlimages/curl --restart=Never -- \
  curl -sS -X POST http://flaresolverr.flaresolverr.svc.cluster.local:8191/v1 \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"request.get","url":"https://www.cloudflare.com/","maxTimeout":60000}'
```

Expected: a JSON response with `"status":"ok"` and a `solution` object containing `response`, `cookies`, and `userAgent`. This validates the headless browser actually launches inside the pod (takes ~5–15s the first time).

If you skip this step, that's fine — Step 2's `/` endpoint already proves the service is alive.

- [ ] **Step 5: No commit needed**

This task is verification only. Nothing was changed.

---

## Self-Review Notes (for the plan author, recorded here for the engineer's awareness)

- **Spec coverage:** All Components-section items in the spec map to Task 1 (manifest creation) and Task 2 (pokemon-bot env var). Data Flow and Testing/Verification map to Task 3. Rollback is a `git revert`; no separate task is needed.
- **Out of scope confirmed:** No edits to `app-scraper.yaml`, no NetworkPolicy, no Ingress, no PVC.
- **Type/name consistency:** Service name `flaresolverr`, namespace `flaresolverr`, deployment `flaresolverr`, env var name `FLARESOLVERR_URL`, port `8191`, and DNS `flaresolverr.flaresolverr.svc.cluster.local` are identical in every place they appear (Task 1, Task 2, Task 3 verification).
- **No companion-prompt work belongs in this plan.** The pokemon-bot application-code change is delivered as a standalone prompt for a separate repo and is explicitly out of this plan's scope.
