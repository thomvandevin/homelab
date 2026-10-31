# Homelab

## The LAN's DHCP runs on homelab-0

AdGuard Home (`apps/templates/app-adguard.yaml`) is the LAN's IPv4 DHCP server; the
Ziggo modem's DHCPv4 server is switched off. Static leases (TV, nodes, Home Assistant
devices) are in that template. The nodes have static IPs in `nixos/` and do not need
DHCP. Two DHCP servers must never run together.

If homelab-0 or AdGuard is down for long:

1. Switch the modem's DHCPv4 server back on (modem UI at 192.168.178.1, Advanced
   settings > DHCP) and set `adguard.dhcp: false` in `apps/values.yaml`.
2. When homelab-0 returns, its kubelet restarts AdGuard with DHCP still on before
   ArgoCD syncs `false`, so run `kubectl -n adguard scale deploy adguard --replicas=0`
   until the sync is done.
3. To move back: switch the modem's DHCPv4 server off and set `adguard.dhcp: true`
   at the same time.

## Placement: homelab-0 is for home

homelab-0 runs the control plane, the home apps and per-node system components only
(design in `docs/superpowers/specs/2026-10-31-node-placement-design.md`).

- Home apps (Home Assistant, Matter, UniFi, AdGuard) use `placement.homelab0`. Adding
  one is a deliberate decision; nothing else goes there.
- Every other Deployment, StatefulSet and CronJob includes `placement.preferWorkers`
  (or `placement.workersOnly` for CI job pods). Chart Applications set the same
  affinity in their values.
- Every ArgoCD Application carries `thomvandev.in/placement: home | workers | system`.
- `scripts/check-placement.sh` enforces both on every PR (`.github/workflows/placement.yaml`).
- Pods that fell back to homelab-0 during a worker outage are moved back by the
  descheduler (`helm-descheduler.yaml`, every 30 minutes).
- Merging anything under `nixos/` makes `.github/workflows/rebuild-nixos.yaml` switch
  all three nodes one by one; check that every Longhorn volume is healthy first.

## Adding or changing an app: update Glance

The dashboard at `http://homelab/` (`apps/templates/app-glance.yaml`, design in
`docs/superpowers/specs/2026-10-06-glance-dashboard-design.md`) discovers apps from
cluster objects, so an app only shows up correctly if it follows these conventions.
Check every item when adding an app, and verify the tile on `http://homelab/` after
ArgoCD syncs.

- The app lives in its own namespace, and that Namespace carries a `glance/icon`
  annotation (`di:`, `sh:`, `si:` or `mdi:` prefix).
- Links are derived, not configured: a Cloudflare tunnel route in
  `cloudflare-tunnel.yaml`, an Ingress with class `tailscale`, or a `LoadBalancer`
  Service with a MetalLB IP. A `hostNetwork` app without a Service gets a
  `thomvandev.in/url` annotation on its Deployment.
- Platform components (no app tile, shown on the Platform page) are added to
  `system_namespaces` in `apps/files/glance/facts.jq`.
- A web UI that none of the above links (for example a plain LAN address) gets a
  bookmark under Tools in `apps/files/glance/glance.yml`.
- If the app needs a new kind of Kubernetes object read by the dashboard, the
  `glance-facts` ClusterRole in `app-glance.yaml` needs the matching `get`/`list`.
