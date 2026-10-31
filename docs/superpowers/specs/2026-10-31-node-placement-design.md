# Node placement: homelab-0 for home, workers for the rest

## Why

homelab-0 is the control plane and carries the single SATA SSD with etcd. The owner
wants it reliable and dedicated to home-critical apps. On 2026-10-31 it ran most of the
owner's own apps as well (pokemon-bot, closet, flaresolverr, swiss-rounds, pokemon-ai):
those use the soft `placement.preferWorkers`, so when the workers were rebooted they
moved to homelab-0 and stayed, because Kubernetes never moves a running pod back.
Several templates and charts have no placement at all and land anywhere. The workers
are unbalanced for the same reason: after its reboot homelab-1 got almost nothing back.

## Goals

- homelab-0 runs the control plane, the home apps and the system components every
  node needs, and nothing else for longer than a worker outage.
- Pods that fell back to homelab-0 move back to a worker by themselves.
- A new app cannot land on homelab-0 by accident: its placement is a conscious choice,
  checked in CI.

## Non-goals

- A taint on homelab-0. Longhorn, MetalLB and CoreDNS must keep running there (Home
  Assistant and Matter volumes attach on homelab-0), and changing Longhorn's
  taint-toleration setting needs every volume detached.
- Moving the system components (Longhorn managers, instance managers and CSI pods,
  MetalLB, CoreDNS, kube-system): they are light and belong on every node.

## Decided by the owner

- Non-home apps keep a soft preference for the workers, so they can still fall back to
  homelab-0 when both workers are down, plus automatic rebalancing afterwards.
- The registry moves to the workers if that is reliable enough. It is: its data is the
  Longhorn volume `registry-pvc` with both replicas on the workers; the original reason
  for pinning it (a hostPath PV at `/mnt/data/registry`, multi-node design 2026-10-05)
  no longer exists.

## The home set (required on homelab-0)

`placement.homelab0`, unchanged: Home Assistant, matter-server, unifi + unifi-mongo,
AdGuard. The registry leaves this set. Nothing else is pinned there.

## Everything else (soft preference for the workers)

`placement.preferWorkers` for every own app and every chart workload that is not home
or a per-node system component. Currently without placement and to be added:
`echo.yaml`, `nginx-reverse-proxy.yaml`, `app-ptcgl.yaml`, `db-backup.yaml`,
`ci-orphan-cleanup.yaml`, `alerts.yaml` (the CronJob), and the chart values of
ingress-nginx, cloudflare-tunnel, actions-runner-controller, cert-manager, argo-cd,
sharry, postgres and postgres-exporter. The builder confirms the exact value keys per
chart. Hard `placement.workersOnly` stays only where it is today (CI job pods).

## Rebalancing (builder's calls, marked)

- The kubernetes-sigs descheduler, as an ArgoCD Helm app running as a CronJob, with
  only `RemovePodsViolatingNodeAffinity` for
  `preferredDuringSchedulingIgnoredDuringExecution`: a pod on homelab-0 whose preferred
  workers have room is evicted and rescheduled there. *Builder's call:* schedule every
  30 minutes, at most a few evictions per run, PodDisruptionBudgets respected,
  DaemonSets and pods with a required node selector never touched.
- Pods with an emptyDir (flaresolverr, scraper, glance caches) must be evictable, or
  they stay on homelab-0. *Builder's call:* allow it.
- Optional, not decided: `LowNodeUtilization` to also even out homelab-1 and homelab-2.
  Left out at first; the owner decides after seeing the affinity rebalancing work.
- The descheduler itself prefers the workers.

## Enforcement for new apps

- A GitHub Actions check on every PR (no secrets needed, static): every template in
  `apps/templates/` that defines a Deployment, StatefulSet or CronJob includes a
  `placement.*` helper, and every Helm chart Application (`helm-*.yaml`) carries an
  annotation `thomvandev.in/placement: home | workers | system` stating the decision.
- `CLAUDE.md` gets a placement section next to the Glance checklist.
- `_placement.tpl`'s header comment drops the outdated "registry hostPath" note.

## Rollout and safety

- Merging changes placement of running pods only where a pod template changes (the
  registry, the templates that gain placement); those roll normally. Pods that already
  have `preferWorkers` move only through the descheduler, a few per run.
- Before merging: all Longhorn volumes healthy, worker headroom checked (moving about
  5 GiB of requests; the workers had about 15 GiB free).
- After: watch the first descheduler runs; every evicted pod is Running on a worker,
  Glance shows homelab-0 with only the home set and system pods, Apps all green.

## Verification

1. CI check fails on a branch where one template has its placement removed, and on a
   chart Application without the annotation; passes on main.
2. Within an hour of merging, `kubectl get pods -A -o wide` on homelab-0 shows only the
   home set, DaemonSets, Longhorn and kube-system pods.
3. The registry runs on a worker and `docker pull registry.snowy-gorgon.ts.net/...`
   (or a CI image pull) works.
4. Cordon nothing; no node reboots are part of this change.
