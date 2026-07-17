# Migrate GCP-built apps off Artifact Registry to the homelab GitLab pattern

**Date:** 2026-07-17
**Status:** Approved — scraper pilot first, then rollout

## Problem

Five projects still build with Google Cloud Build and store images in Google
Artifact Registry (`gcr.io/...`), which is billed monthly. The homelab pulls
those images via per-app `gcr-*-secret` pull secrets. Meanwhile `closet` and
`pokemon-bot` already use a **free** in-house pattern: build on the in-cluster
GitLab runner and push to GitLab's Container Registry.

The five projects:

| Project | gcr image | homelab ns / deployment | current pull-secret value |
|---|---|---|---|
| scraper | `gcr.io/cavempt-scraper/cavempt-scraper` | `scraper` / `scraper` | `gcr.scraper` |
| swiss-rounds | `gcr.io/swiss-rounds/swiss-rounds` | `swiss-rounds` / `swiss-rounds` | `gcr.swiss_rounds` |
| end-of-year | `gcr.io/thomvandevin-end-of-year/end-of-year` | `end-of-year` / `end-of-year` | `gcr.end_of_year` |
| limitless-tournament-decks | `gcr.io/limitless-tournament-decks/...` | `limitless-tournament-decks` | `gcr.limitless_tournament_decks` |
| thomvandev.in | **unknown** — no CI/Dockerfile/manifest in repo | not a homelab k8s app (yet found) | none |

## Goal

Stop all Artifact Registry / Cloud Build charges by moving each project's build
onto hardware already running (the homelab GitLab group runner) and its images
into the free GitLab Container Registry — **without** shifting the cost onto
gitlab.com shared CI minutes. Every CI job must run on the `homelab`-tagged
in-cluster runner.

## Target pattern (established by `pokemon-bot` / `closet`)

For each project:

1. **Project lives under the `thomvandevin-projects` GitLab group** — that group
   owns the homelab group runner. (The projects are currently under the personal
   `thomvandevin` namespace, which has no runner. **Manual move required.**)
2. **CI** (`.gitlab-ci.yml`): all jobs `tags: [homelab]`. A Kaniko `build` job
   pushes `:$CI_COMMIT_SHA` and `:latest` to `$CI_REGISTRY_IMAGE`. A `deploy` job
   (`bitnami/kubectl`) runs `kubectl rollout restart` + `rollout status` against
   the app's deployment, authenticating in-cluster via the runner's
   `gitlab-ci-job` ServiceAccount.
3. **`cloudbuild.yml` deleted.**
4. **Homelab manifest**: replace the `gcr-*-secret` (dockerconfigjson from
   `.Values.gcr.<app>`) with a `gitlab-registry-secret` (from a new
   `.Values.<app>.registry` deploy-token dockerconfigjson); point the image at
   `registry.gitlab.com/thomvandevin-projects/<project>:latest` with
   `imagePullPolicy: Always`; add a per-namespace deployer `Role` +
   `RoleBinding` for the `gitlab-ci-job` SA so the deploy job may restart the
   deployment.

## Decisions

- **Build tool: Kaniko.** Rootless, matches `pokemon-bot`; the runner is already
  `privileged=true` so dind would also work, but Kaniko keeps parity with the
  closest sibling.
- **Auto-deploy: yes**, via `kubectl rollout restart` + per-namespace RBAC.
- **SAST: dropped** from these projects' CI (matches `closet`, keeps the pipeline
  lean and fully off shared runners). Reversible — can be re-added retagged to
  `homelab` if wanted.
- **Registry pull-secret value key: `<app>.registry`** (flat, matching
  `pokemon_bot.registry` / `pokemon_ai.registry`).

## Scraper pilot — exact changes

### scraper repo (`gitlab.com/thomvandevin-projects/scraper` after move)

- **`.gitlab-ci.yml`** — replaced with a homelab-runner Kaniko build + kubectl
  deploy pipeline (`build` and `deploy` stages, `main` only).
- **`cloudbuild.yml`** — deleted.
- **`README.md`** — Build reference updated to the GitLab Container Registry.

### homelab repo (`apps/templates/app-scraper.yaml`)

- Add `scraper-deployer` Role (`get,list,watch,patch` on `apps/deployments`) and
  `gitlab-runner-scraper-deploy` RoleBinding for `gitlab-ci-job` in
  `gitlab-runner`.
- Replace `gcr-scraper-secret` (`.Values.gcr.scraper`) with
  `gitlab-registry-secret` (`.Values.scraper.registry`).
- Deployment: `image: registry.gitlab.com/thomvandevin-projects/scraper:latest`,
  `imagePullPolicy: Always`, `imagePullSecrets: gitlab-registry-secret`.
- The two CronJobs and Service are unchanged (they call the in-cluster service).

## Manual / out-of-band steps (owner: Thom)

These cannot be done from code and gate the cutover:

1. **Move the GitLab project** into the `thomvandevin-projects` group.
2. **Create a GitLab deploy token** (scope: `read_registry`) and store its
   dockerconfigjson (base64) in SOPS `apps/secrets.yaml` as `scraper.registry`,
   replacing `gcr.scraper`.
3. Push to `main` and confirm the homelab-runner pipeline builds + deploys.
4. **After verifying the pod runs the GitLab image**, delete the old GCP
   `cavempt-scraper` Artifact Registry repo / project to actually end the
   billing. (Do this last, per project, only once the new image is confirmed
   serving.)

**Sequencing (important):** the homelab manifest references a new top-level
`scraper` values key, so the SOPS `scraper.registry` entry (step 2) must be
committed **together with or before** the `app-scraper.yaml` change lands —
otherwise ArgoCD renders `nil pointer evaluating interface {}.registry` and the
whole Application sync fails. Order: add SOPS value + merge homelab manifest →
ArgoCD syncs (creates the RBAC + pull secret) → then the scraper CI deploy job
can restart the deployment. Confirmed locally: `helm template` fails without the
value and renders cleanly with it.

## Verification

- CI: pipeline runs entirely on the `homelab` runner (no shared-minute jobs);
  `build` pushes to `registry.gitlab.com/thomvandevin-projects/scraper`; `deploy`
  restarts `deployment/scraper` and `rollout status` returns success.
- Cluster: `kubectl -n scraper get deploy scraper -o jsonpath='{..image}'` shows
  the `registry.gitlab.com/...` image; pod is `Running`; the two CronJobs still
  hit `scraper-svc` successfully.
- Billing: GCP Cloud Build + Artifact Registry usage for the project drops to
  zero after the old repo is deleted.

## Rollout to the remaining three (after the pilot is proven)

Same template; per-project specifics:

| Project | deployment / ns | new image | new secret value | notes |
|---|---|---|---|---|
| swiss-rounds | `swiss-rounds` / `swiss-rounds` | `registry.gitlab.com/thomvandevin-projects/swiss-rounds:latest` | `swiss_rounds.registry` | served image (frontend); auto-deploy optional but included for consistency |
| end-of-year | `end-of-year` / `end-of-year` | `.../end-of-year:latest` | `end_of_year.registry` | Node app |
| limitless-tournament-decks | `limitless-tournament-decks` | `.../limitless-tournament-decks:latest` | `limitless_tournament_decks.registry` | Node app |

Each also needs the group move + deploy token + SOPS entry + GCP cleanup.

## thomvandev.in — investigate first (separate track)

No `.gitlab-ci.yml`, `Dockerfile`, `cloudbuild.yml`, gcr secret, or homelab
`app-*.yaml` exists for it — it's a static portfolio (`designs/`, `portfolio/`,
`projects/`). The Artifact Registry cost it incurs is not visible in the repo
working tree. Before migrating, determine how it is actually built and hosted
(GitLab CI/CD settings-only config, a subdirectory build, Cloud Run, Firebase
Hosting, or Cloudflare). Design its migration once that is known.
