# Network-wide DNS blocking with AdGuard Home

## Why

The Sony A80J TV was debloated over ADB on 2026-10-31 (Samba TV ACR, Sony telemetry
agents and promo packages disabled). What is left of its tracking, plus what every
other device in the house sends, can only be stopped at the DNS level. The TV is the
trigger; the result covers the whole household.

## Goals

- Block ads and trackers for every device on the LAN, the TV included.
- Never take the house offline: when AdGuard or the whole cluster is down, DNS keeps
  working, unfiltered.
- All configuration, including the allowlist, lives in this repo so a Claude session
  can fix a false block by editing a file and opening a PR.

## Non-goals

- Per-device statistics or per-device rules (consciously traded for reliability, see
  "How DNS flows").
- DNS over HTTPS/TLS towards clients.
- Replacing the FRITZ!Box as DHCP or DNS server.

## Anti-goals

- Anyone in the house noticing the blocker other than through fewer ads. Strict lists
  are accepted as a starting point; individual breakage is fixed with an allowlist
  entry, and the lists are made more lenient later if that keeps happening.
- Settings that only exist in the AdGuard web UI.

## How DNS flows (decided)

Clients keep using the FRITZ!Box (192.168.178.1) as their DNS server, over IPv4 and
IPv6, exactly as today. The only router change is the FRITZ!Box's own upstream, under
Internet > Account Information > DNS Server:

- preferred DNSv4 server: the AdGuard LoadBalancer IP
- alternative DNSv4 server: a public resolver

The FRITZ!Box falls back to the alternative when AdGuard does not answer. The cost is
that AdGuard sees every query as coming from the FRITZ!Box. The owner makes this
change by hand in the FRITZ!Box UI; it is not in the repo.

AdGuard's own upstream is a public encrypted resolver, never the FRITZ!Box, so a
query can never loop router → AdGuard → router.

## The cluster stays unfiltered (decided)

Cluster workloads (scrapers, CI runners, workspace sessions, ArgoCD) have no human
watching for false blocks, so they must not go through AdGuard. Today
`environment.etc."k3s/resolv.conf"` in `nixos/configuration.nix` lists the FRITZ!Box
(192.168.178.1) first, which after the router change would filter every pod. That
file points at public resolvers instead (for example Quad9 and Cloudflare), and every
node is rebuilt. This also keeps AdGuard's own lookups from looping through the
router back to itself. Before dropping the router from that file, the builder checks
whether anything in the cluster resolves LAN names through it (`*.fritz.box`, bare
hostnames); if so, those zones get a forward to 192.168.178.1 in
`apps/templates/coredns-custom.yaml`, like the tailnet zone. *Builder's call.*

## IPv6 (decided)

AdGuard is IPv4-only, because the cluster and the MetalLB pool are. If the FRITZ!Box
turns out to send some lookups to its own DNSv6 upstreams and cannot be told not to,
that partial gap is accepted and revisited later. No dual-stack work in this project.

## Blocklists (decided)

- hagezi Light
- Perflyst SmartTV
- a Dutch regional list: prefer the Dutch entry in AdGuard Home's built-in filter
  catalogue; if there is none, EasyDutch
- allowlist from the start: `update.biv.sony.tv`, `reg.biv.sony.tv`,
  `service.biv.sony.tv` (Sony firmware update and registration; the SmartTV list
  leaves them open on purpose)

## Configuration in git (decided)

The full AdGuard Home configuration, lists and allowlist included, is rendered from
this repo and applied by ArgoCD. Changes made in the web UI are lost on the next
restart or sync, and that is intended: git is the only source of truth. The web UI
stays useful for the query log and for testing.

## Deployment (builder's calls, marked as such)

- `apps/templates/app-adguard.yaml`, namespace `adguard`, following the existing app
  templates. *Builder's call.*
- AdGuard Home rewrites its config file on start, so the ConfigMap is copied into a
  writable volume by an init container rather than mounted read-only. *Builder's call.*
- One replica pinned to homelab-0 (`placement.homelab0`), where the home-critical
  apps (Home Assistant, Matter) run. *Decided by the owner.* The FRITZ!Box fallback
  covers the pod or node restarting.
- No persistent volume: filters re-download and stats reset on restart. That also
  fits homelab-0, which holds no Longhorn replicas. *Builder's call.*
- DNS on a `LoadBalancer` Service (UDP and TCP 53) with a fixed MetalLB IP,
  192.168.178.160, pinned with the `metallb.io/loadBalancerIPs` annotation and
  `externalTrafficPolicy: Local`, so homelab-0 itself answers for the IP and DNS
  does not depend on a worker being up. *Builder's call.*
- Upstream: Quad9 and Cloudflare over DoH, with plain bootstrap resolvers.
  *Builder's call.*
- Blocking mode that returns a definitive answer (NXDOMAIN or the null IP), never
  REFUSED or SERVFAIL, so the FRITZ!Box does not treat a block as a failure and retry
  the alternative server. *Builder's call*, verified by the test below.
- Web UI on the tailnet through an Ingress with class `tailscale`, like ArgoCD and
  Longhorn, and on the LAN as the first port (80) of the DNS LoadBalancer Service,
  because Glance builds its LAN link from that first port. The admin password is a
  bcrypt hash in `apps/secrets.yaml` (SOPS). *Builder's call* for the LAN port.
- An "AdGuard down" alert: a DNS probe against the LoadBalancer IP added to the
  existing kubectl + Pushover CronJob in `apps/templates/alerts.yaml`. Prometheus is
  disabled (`prometheus.enabled: false`, SSD wear), so a PrometheusRule would never
  fire. The fallback makes an outage silent, so nobody would otherwise notice.
  *Builder's call.*
- Glance: follow the checklist in `CLAUDE.md` (namespace `glance/icon`, link via the
  tailscale Ingress).

## Verification

After the router change, from a LAN client:

1. A domain on hagezi Light is blocked, over IPv4 and over IPv6 (ask the FRITZ!Box's
   IPv6 address). If IPv6 lookups bypass AdGuard because the FRITZ!Box uses its own
   DNSv6 upstreams, try to close that in the router; if the router cannot, record the
   gap in this document and carry on (see "IPv6").
2. A normal domain resolves, and `update.biv.sony.tv` resolves.
3. Scale AdGuard to zero: lookups keep working within seconds (fallback works).
4. With AdGuard up, the AdGuard query log shows all LAN lookups. If a large share
   still goes to the alternative server while AdGuard is healthy, the FRITZ!Box
   splits load between the two; report that to the owner before going further.
5. On the TV: Netflix, Videoland, Plex, SmartTube, casting and AirPlay still work.
6. From a pod: a domain on hagezi Light still resolves (the cluster is unfiltered).

## Left to the builder

Image and version pinning (digest, like the other apps), resource requests, exact
list URLs, the alert threshold and the order of the work.
