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
- Replacing the Ziggo modem as the internet router.

## Anti-goals

- Anyone in the house noticing the blocker other than through fewer ads. Strict lists
  are accepted as a starting point; individual breakage is fixed with an allowlist
  entry, and the lists are made more lenient later if that keeps happening.
- Settings that only exist in the AdGuard web UI.

## How DNS flows (decided, revised 2026-10-31)

The router is a Ziggo SmartWifi modem (192.168.178.1), not a FRITZ!Box, as first
assumed. Its DHCP hands devices Ziggo's DNS servers (84.116.46.20/21) directly, and
its custom DNS field rejects LAN addresses, so it cannot point the house at AdGuard
or forward to it. Instead AdGuard takes over DHCP for IPv4:

- The owner switches off the modem's DHCPv4 server; AdGuard's built-in DHCP server
  on homelab-0 hands out addresses.
- DHCP option 6 (DNS) is `192.168.178.160` (AdGuard) then `9.9.9.9`. The public
  second server keeps names working when homelab-0 or AdGuard is down. The owner
  accepts that devices sometimes use the second server, so some lookups skip the
  filter.
- Devices keep their address for a full lease after homelab-0 goes down; only new
  devices and expired leases need it. Rollback is switching the modem's DHCPv4
  server back on.
- AdGuard now sees each device by its own address, so per-device stats come for
  free (still no per-device rules).

AdGuard's own upstream is a public encrypted resolver, never the modem, so nothing
loops.

## DHCP (decided)

Values read from the modem on 2026-10-31:

- Gateway `192.168.178.1`, subnet `255.255.255.0`, lease `86400` s (same as the modem).
- Dynamic range `192.168.178.30` to `192.168.178.149`: clear of the reservations
  below and of the MetalLB pool `192.168.178.155-249`. (The modem's range `.5-.209`
  overlapped that pool; this fixes it.)
- Static leases, migrated from the modem's reserved list:

  | MAC | IP | Device |
  |---|---|---|
  | `24:5a:4c:23:ad:d8` | 192.168.178.5 | WIFI_THOMALIES (access point) |
  | `d4:5d:64:1d:09:86` | 192.168.178.10 | unknown, kept |
  | `08:00:27:fa:ba:92` | 192.168.178.11 | unknown (VirtualBox MAC), kept |
  | `9e:13:9e:32:ea:90` | 192.168.178.12 | SLZB-MR5U (Zigbee/Thread) |
  | `9c:13:9e:32:ea:90` | 192.168.178.13 | SLZB-MR5U second interface |
  | `c4:41:1e:b2:45:1c` | 192.168.178.14 | Sony A80J TV |
  | `22:4a:cb:8b:5b:35` | 192.168.178.20 | homelab-media |
  | `d8:9e:f3:8c:29:ba` | 192.168.178.151 | homelab-0 |
  | `a4:bb:6d:7c:eb:5d` | 192.168.178.152 | homelab-1 |
  | `a4:bb:6d:78:03:2e` | 192.168.178.153 | homelab-2 |

  Plus, as builder's call, leases for the Home Assistant devices that currently sit
  at a dynamic address the integrations point at: HomeWizard P1 `3c:39:e7:2c:7b:12`
  → .21 and the printer `34:9F:7B:A0:45:8F` → .22.
- The three nodes get static IPv4 configuration in NixOS (homelab-0 `enp1s0` .151,
  homelab-1 and homelab-2 `eno2` .152/.153, gateway .1), because homelab-0 cannot get
  its own address from a DHCP server that runs on it. Their static leases stay as a
  safety net.
- AdGuard runs with `hostNetwork` on homelab-0 (DHCP needs the LAN broadcast domain);
  `dnsPolicy: ClusterFirstWithHostNet`, like matter-server. Ports 53, 67 and 3000 are
  free on the host (checked). The `.160` LoadBalancer stays the DNS address handed out.
- Static leases live in git like everything else. Dynamic leases must survive a pod
  restart, so AdGuard's work directory moves to a hostPath on homelab-0 (homelab-0
  holds no Longhorn replicas). How git-managed static leases and persisted dynamic
  leases are combined at start is the builder's call.
- Cutover order: deploy with DHCP disabled and verify, then the owner switches the
  modem's DHCPv4 off and DHCP is enabled in the same minute. Devices move over as
  they renew (within a day), or immediately after reconnecting.

## The cluster stays unfiltered (decided)

Cluster workloads (scrapers, CI runners, workspace sessions, ArgoCD) have no human
watching for false blocks, so they must not go through AdGuard. Today
`environment.etc."k3s/resolv.conf"` in `nixos/configuration.nix` lists the router
(192.168.178.1) first, which after the router change would filter every pod. That
file points at public resolvers instead (for example Quad9 and Cloudflare), and every
node is rebuilt. This also keeps AdGuard's own lookups from looping through the
router back to itself. Before dropping the router from that file, the builder checks
whether anything in the cluster resolves LAN names through it (`*.fritz.box`, bare
hostnames); if so, those zones get a forward to 192.168.178.1 in
`apps/templates/coredns-custom.yaml`, like the tailnet zone. *Builder's call.*

## IPv6 (decided)

AdGuard is IPv4-only, because the cluster and the MetalLB pool are. The modem's
DHCPv6 is stateless and hands out Ziggo's IPv6 DNS, so dual-stack devices can resolve
past AdGuard. That gap is accepted and measured after cutover (AdGuard query volume
per device); no dual-stack work in this project.

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
  apps (Home Assistant, Matter) run. *Decided by the owner.* The `9.9.9.9` second DNS server
  covers the pod or node restarting.
- Work directory (leases, filters, stats) on a hostPath on homelab-0, since DHCP
  leases must survive a restart; homelab-0 holds no Longhorn replicas, and the pod is
  pinned there anyway. *Revised with the DHCP decision.*
- DNS on a `LoadBalancer` Service (UDP and TCP 53) with a fixed MetalLB IP,
  192.168.178.160, pinned with the `metallb.io/loadBalancerIPs` annotation and
  `externalTrafficPolicy: Local`, so homelab-0 itself answers for the IP and DNS
  does not depend on a worker being up. *Builder's call.*
- Upstream: Quad9 and Cloudflare over DoH, with plain bootstrap resolvers.
  *Builder's call.*
- Blocking mode that returns a definitive answer (NXDOMAIN or the null IP), never
  REFUSED or SERVFAIL, so a client does not treat a block as a failure and retry
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

Before cutover (DHCP still on the modem): the DNS checks already done for #820 still
pass with AdGuard on `hostNetwork`, and the nodes keep their addresses after a reboot
with static configuration.

After cutover, from LAN clients:

1. A device that reconnects gets an address in `.30-.149`, gateway `.1`, and DNS
   `192.168.178.160, 9.9.9.9`. The TV reconnects at `.14`, and the AdGuard UI lists it
   under static leases.
2. A domain on hagezi Light answers NXDOMAIN through `.160`; a normal domain and
   `update.biv.sony.tv` resolve.
3. Scale AdGuard to zero: devices keep their address and still resolve names (via
   `9.9.9.9`). Scale back.
4. After a day, the AdGuard query log shows per-device traffic for most devices.
   Record how much IPv6 or second-server traffic bypasses it in this document.
5. On the TV: Netflix, Videoland, Plex, SmartTube, casting and AirPlay still work.
   Home Assistant still reaches its devices (SLZB, HomeWizard, printer, TV).
6. From a pod: a domain on hagezi Light still resolves (the cluster is unfiltered).

Recovery if homelab-0 is down for long: switch the modem's DHCPv4 server back on.
This goes in `CLAUDE.md` so a later session knows.

## Left to the builder

Image and version pinning (digest, like the other apps), resource requests, exact
list URLs, the alert threshold and the order of the work.
