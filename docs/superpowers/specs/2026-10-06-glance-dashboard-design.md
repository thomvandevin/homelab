# Glance dashboard for the cluster

## Goal

One page, reachable as `http://homelab/` on the tailnet (the same way
`http://homelab-media/` works), that shows the state of the cluster and a
tile per application with working links, without editing the dashboard when
applications come and go.

## Approach

Glance (the same tool as on the media box) runs in the cluster next to a
small `facts` sidecar: a shell loop that reads the Kubernetes API with
`kubectl` every 30 seconds and lets one `jq` program derive a single
`facts.json` (nodes, apps with links, workloads, storage, platform, CI), served
on `localhost`. Glance's `custom-api` widgets render that file. Glance's own
templating cannot parse Kubernetes quantities (`3500m`, `32751080Ki`), which is
why the derivation lives in jq rather than in the widgets. Nothing is compiled
or built: the dashboard is one Glance YAML and one jq file, and every list on
it comes from objects the cluster already has.

Rejected: Homepage (gethomepage). Its discovery needs an annotation on every
Ingress, it is a second tool to learn next to the media Glance, and its cluster
widgets show less than we can render ourselves.

## What is derived from where

| Dashboard element | Source object | Convention relied on |
|---|---|---|
| App tile (one per namespace) | Deployments, StatefulSets, Pods grouped by namespace | every app lives in its own namespace |
| Own app vs platform | first container image starts with `registry.gitlab.com/` | own images come from the GitLab registry |
| Public link | ConfigMap `cloudflare-tunnel/cloudflare-tunnel`, key `config.yaml`: the `hostname:` whose `service:` ends in `.<namespace>.svc` | tunnel routes reference `svc.namespace.svc.cluster.local` |
| Tailnet link | Ingress with class `tailscale`: `status.loadBalancer.ingress[0].hostname` | Tailscale operator fills the status |
| LAN link | Service `type: LoadBalancer` with an IP in `status` | MetalLB |
| Explicit link | annotation `thomvandev.in/url` on a Deployment | only for hostNetwork apps with no Service (UniFi) |
| Icon | annotation `glance/icon` on the Namespace, a workload, or the ArgoCD Application; `di:`, `sh:`, `si:`, `mdi:` prefixes resolve to the icon CDNs Glance uses | every app |
| App health | ArgoCD `Application` sync and health status | one Application per app |
| Node cards | Nodes + `metrics.k8s.io` + sum of pod requests per node | |
| Storage | Longhorn `volumes.longhorn.io`, `nodes.longhorn.io` | |
| CI | pods in `gitlab-runner*` and `default` (ARC) namespaces; GitLab GraphQL for pipelines, REST for open MRs | token with `read_api` |

System namespaces (`kube-system`, `longhorn-system`, `metallb-system`,
`cert-manager`, `tailscale`, `cloudflare-tunnel`, `argocd`, `glance`) are
shown on the Platform page, not as app tiles.

## Pages

1. **Home**: node cards (role, Ready, kernel, CPU and memory used / requested /
   allocatable, Longhorn disk), a health strip (ArgoCD apps healthy, pods not
   running, volumes not healthy, nodes with a kernel update pending), then the
   app grid: own apps first, platform second. Each tile: name, ready/desired,
   restarts, status dot, links.
2. **Workloads**: table of every Deployment, StatefulSet and DaemonSet (ready,
   restarts, age, image tag, node), sorted by restarts; CronJobs with last
   schedule; runner managers and running CI job pods.
3. **Storage**: Longhorn volumes (PVC, namespace, size, replicas and their
   nodes, robustness, engine), per-node disk (max, available, scheduled).
4. **Platform**: ArgoCD applications (sync, health, revision), Ingresses,
   LoadBalancer IPs in use, upstream releases of the charts we run.
5. **GitLab** (only rendered when a token is configured): latest pipeline per
   project across `thomvandevin-projects` and `swiss-rounds`, open merge
   requests, and the runners' job pods.

Theme: the media box's tokens (dark, green primary, red negative), logo text
`HL`, app name `Homelab`.

## Plumbing

- `apps/templates/app-glance.yaml`: Namespace `glance`, ServiceAccount,
  ClusterRole (`get`, `list` on nodes, pods, services, pvcs, deployments,
  statefulsets, daemonsets, cronjobs, jobs, ingresses, `metrics.k8s.io`,
  `longhorn.io` volumes/nodes/replicas, `argoproj.io` applications; `get` on the
  one tunnel ConfigMap by name), ClusterRoleBinding, a
  config ConfigMaps (Glance YAML, facts script and jq program via
  `.Files.Get`), the two-container Deployment, and a `LoadBalancer` Service with `loadBalancerClass: tailscale`
  and `tailscale.com/hostname: homelab`.
- The `facts` sidecar (`alpine/k8s`, which ships kubectl and jq) runs under the
  ServiceAccount; Glance itself needs no API access and reads
  `http://localhost:8081/facts.json`.
- GitLab token: `glance.gitlab_token` in `apps/secrets.yaml`, mounted as an
  env var; the GitLab page is wrapped in `{{ if .Values.glance.gitlab_token }}`.
- Placement: `preferWorkers`. Requests 50m / 64Mi, memory limit 256Mi, no CPU
  limit.
- Image `glanceapp/glance:v0.8.6`, Renovate pins the digest and proposes updates.

## Out of scope

- Public exposure through the tunnel.
- Prometheus-backed history; Glance shows the current state only.
- Editing the media box's Glance.
