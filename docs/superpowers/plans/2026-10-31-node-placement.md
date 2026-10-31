# Node Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep homelab-0 for the control plane, home apps and per-node system components; every other workload prefers the workers, is moved back automatically, and new apps must declare their placement.

**Architecture:** Soft `placement.preferWorkers` affinity on every non-home workload (own templates and chart values), a descheduler CronJob that evicts pods violating that preference, and a static CI check on placement.

**Tech Stack:** Helm templates in `apps/templates` (ArgoCD, tracks `main`), descheduler chart 0.37.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-31-node-placement-design.md`

## Global Constraints

- Branch `feat/node-placement`, worktree `~/Projects/thomvandevin/homelab-placement`; squash-merge and delete the branch when done. No AI attribution in commits.
- Render check, from `apps/`: `render() { K=../../homelab/key.txt; SOPS_AGE_KEY_FILE=$K helm template . -f <(SOPS_AGE_KEY_FILE=$K sops -d secrets.yaml) 2>/dev/null; }`.
- Home set stays `placement.homelab0`: home-assistant, matter-server, unifi, unifi-mongo, adguard. Nothing else.
- Chart value keys (verified by rendering): ingress-nginx `controller.affinity`; actions-runner-controller `affinity`; cert-manager `affinity`, `webhook.affinity`, `cainjector.affinity`; argo-cd `global.affinity.nodeAffinity: {type: soft, matchExpressions: [worker]}`; sharry `affinity`; postgresql `primary.affinity`; prometheus-postgres-exporter `affinity`; tailscale-operator `operatorConfig.affinity`; gitlab-runner `affinity` (both).
- Annotation on every `helm-*.yaml` Application: `thomvandev.in/placement`: `home` (homeassistant), `system` (longhorn, metal-lb), `workers` (all others).
- No node reboots, no taints, no Longhorn setting changes.

## Review Focus

1. A home pod must never be evicted or moved: the descheduler only acts on preferred affinity, and home pods use a required node selector. Pinned in Task 3 step 1.
2. The descheduler must not evict when the pod cannot fit a worker (`nodeFit: true`), and at most 3 per node per run. Pinned in Task 3 step 1.
3. The registry move keeps its data (Longhorn RWO volume reattaches). Pinned in Task 5 step 3.
4. The CI check fails on a missing placement and passes on main. Pinned in Task 4 step 2.

---

### Task 1: Placement for own templates

**Files:** `apps/templates/{docker-registry,echo,nginx-reverse-proxy,app-ptcgl,db-backup,ci-orphan-cleanup,alerts}.yaml`, `apps/templates/_placement.tpl` (header comment).

- [ ] Step 1: Check (fails now): `render | yq 'select(.kind=="Deployment" or .kind=="StatefulSet" or .kind=="CronJob") | select(.metadata.namespace | test("^(home-assistant|matter-server|unifi|adguard)$") | not) | .metadata.namespace + "/" + .metadata.name + " " + ((.spec.template.spec.affinity // .spec.jobTemplate.spec.template.spec.affinity // {}) | has("nodeAffinity") | tostring)' | grep false` lists the registry and the six templates.
- [ ] Step 2: Registry `placement.homelab0` becomes `placement.preferWorkers`; the six templates get `{{- include "placement.preferWorkers" . | nindent N }}` in the pod spec (CronJobs: in `jobTemplate.spec.template.spec`). `_placement.tpl` header: drop "the registry hostPath".
- [ ] Step 3: The step 1 check prints nothing for own templates (charts are Task 2). Commit `feat(placement): own templates prefer the workers, registry leaves homelab-0`.

### Task 2: Placement for charts and the annotation

**Files:** all `apps/templates/helm-*.yaml`.

- [ ] Step 1: Add the keys from Global Constraints with the same affinity as `placement.preferWorkers` (inline YAML, since `valuesObject` cannot include the helper at the right depth), and the `thomvandev.in/placement` annotation on every Application.
- [ ] Step 2: `render | yq 'select(.kind=="Application") | .metadata.name + " " + (.metadata.annotations["thomvandev.in/placement"] // "MISSING")'` shows no MISSING; each changed Application's rendered `valuesObject` contains `thomvandev.in/role`. Commit `feat(placement): chart workloads prefer the workers`.

### Task 3: Descheduler

**Files:** create `apps/templates/helm-descheduler.yaml`.

- [ ] Step 1: ArgoCD Application, chart `descheduler` 0.37.0 from `https://kubernetes-sigs.github.io/descheduler/`, namespace `kube-system`, annotation `thomvandev.in/placement: workers`, values: `kind: CronJob`, `schedule: "*/30 * * * *"`, preferWorkers `affinity`, and `deschedulerPolicy: {maxNoOfPodsToEvictPerNode: 3, profiles: [{name: workers, pluginConfig: [{name: DefaultEvictor, args: {nodeFit: true, podProtections: {defaultDisabled: [PodsWithLocalStorage]}}}, {name: RemovePodsViolatingNodeAffinity, args: {nodeAffinityType: [preferredDuringSchedulingIgnoredDuringExecution]}}], plugins: {deschedule: {enabled: [RemovePodsViolatingNodeAffinity]}}}]}`. Render the chart locally with these values (`helm template`) and confirm the policy ConfigMap contains only that plugin.
- [ ] Step 2: Commit `feat(descheduler): move pods back to the workers after a fallback`.

### Task 4: CI check and docs

**Files:** create `scripts/check-placement.sh`, `.github/workflows/placement.yaml`; modify `CLAUDE.md`.

- [ ] Step 1: `scripts/check-placement.sh`: fails, listing files, when a template defining a Deployment, StatefulSet or CronJob lacks `include "placement.`, or a `kind: Application` file lacks `thomvandev.in/placement:`. Workflow runs it on pull requests touching `apps/templates/**`.
- [ ] Step 2: Run it on the branch: passes. Remove the include from a copy of one template in a temp dir: fails naming it.
- [ ] Step 3: `CLAUDE.md`: a "Placement" section (home set, everything else preferWorkers, charts annotated, CI enforces it). Commit `ci: require an explicit placement for every workload`.

### Task 5: Merge and verify

- [ ] Step 1: Preconditions: all Longhorn volumes healthy; worker request headroom > 6 GiB memory.
- [ ] Step 2: PR, merge, ArgoCD sync.
- [ ] Step 3: Registry pod Running on a worker, its volume attached there and healthy, `curl -s https://registry.snowy-gorgon.ts.net/v2/_catalog` lists repositories.
- [ ] Step 4: Trigger the descheduler once (`kubectl -n kube-system create job --from=cronjob/descheduler desched-now`), read its log: only preferred-affinity evictions, none in the home namespaces. Repeat until homelab-0 shows only the home set, DaemonSets, Longhorn and kube-system pods; Glance all green; delete the manual jobs.
