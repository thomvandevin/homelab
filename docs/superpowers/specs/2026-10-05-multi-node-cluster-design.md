# Multi-node cluster: adding two worker nodes

## Goal

Grow the single-node k3s cluster to three nodes so CPU-heavy workloads (own
applications and CI runners) stop competing with the control plane and the
home-automation stack on `homelab-0`.

Hardware:

| Host | Machine | CPU | RAM | Disk | IP | Role |
|---|---|---|---|---|---|---|
| homelab-0 | existing | i5-7500T, 4c/4t | 32 GB | 256 GB SATA | 192.168.178.151 | control plane + etcd, hardware-bound apps |
| homelab-1 | Dell OptiPlex 5080 Micro | i5-10500T, 6c/12t | 16 GB | 256 GB | 192.168.178.152 | worker |
| homelab-2 | Dell OptiPlex 5080 Micro | i5-10500T, 6c/12t | 16 GB | 256 GB | 192.168.178.153 | worker |

Decisions already made by the owner: `homelab-0` stays the single control
plane; the two new nodes are general-purpose workers; own-built applications
move to the workers where that makes sense.

## Current state (verified 2026-10-05)

- `nixos/flake.nix` already iterates a `nodes` list and passes `meta.hostname`;
  `configuration.nix` adds `--server https://192.168.178.151:6443` for any
  non-`homelab-0` host. Everything else is single-host:
  - `services.k3s.role = "server"` and `--cluster-init` for every host.
  - `tokenFile` is commented out. The `k3s-token` secret in `nixos/secrets.yaml`
    does **not** match the live server's `/var/lib/rancher/k3s/server/node-token`,
    so no node could join with it.
  - One shared `hardware-configuration.nix` (SATA, `kvm-intel`) and one
    `disko-configuration.nix` hard-wired to `/dev/sda`.
  - `k3s-longhorn-webhook-cleanup` runs `k3s kubectl` with the server
    kubeconfig, which does not exist on an agent.
  - `nixos/hosts/` and `nixos/modules/` exist but are empty.
- `homelab-0` gets `.151` from a DHCP reservation (NetworkManager, no static
  config in NixOS).
- Tailscale: hosts join the tailnet with a tagged auth key (`tag:k8s`, minted
  2026-08-26). The GitHub rebuild workflow reaches hosts by MagicDNS name
  (`host: homelab-0`), so workers must also join the tailnet.
- Longhorn 1.12.1, `defaultClassReplicaCount: 1`, all 11 volumes at 1 replica
  (86 GB scheduled), all on `homelab-0`'s root btrfs.
- `homelab-0`: 96% of CPU requested, load ~7 on 4 cores, 43% memory.
- `.github/workflows/rebuild-nixos.yaml` builds and switches a hard-coded
  `host: ["homelab-0"]` matrix from in-cluster ARC runners.

## Design

### 1. NixOS layout

Move host-specific files into per-host directories and keep one shared
`configuration.nix`:

```
nixos/
  flake.nix                  nodes = { homelab-0 = {role=server; disk=/dev/sda; hardware=...}; homelab-1/2 = {role=agent; disk=/dev/nvme0n1; hardware=...} }
  configuration.nix          shared; role-dependent k3s block
  disko-configuration.nix    shared; device = meta.disk
  hosts/
    homelab-0.nix            hardware config (moved, unchanged: ahci/sd_mod, kvm-intel)
    optiplex-5080-micro.nix  hardware config for both workers (nvme, xhci_pci, ahci, usbhid, sd_mod, kvm-intel)
```

`flake.nix` passes `meta = { hostname; role; disk; }` and imports the
node's `hardware` file. `homelab-0`'s system closure must be
identical before and after the refactor (verified with
`nixos-rebuild build` on the host plus `nix store diff-closures`).

### 2. k3s roles

```nix
services.k3s = {
  enable = true;
  role = meta.role;                       # "server" | "agent"
  tokenFile = config.sops.secrets.k3s-token.path;   # agents only
  serverAddr = "https://192.168.178.151:6443";      # agents only
  clusterInit = meta.role == "server";
  extraFlags = server: write-kubeconfig-mode, --disable servicelb/traefik/local-storage
               agent:  none
  nodeLabel = [ "thomvandev.in/role=worker" ];   # agents only
  gracefulNodeShutdown.enable = true;     # agents: drain pods on reboot/poweroff
};
```

- The `k3s-token` secret is replaced with the live server node token so
  agents can join. The server does not read `tokenFile` (unchanged behaviour).
- `k3s-longhorn-webhook-cleanup` becomes server-only.
- `services.openiscsi`, the `/usr/local/bin` tmpfiles rule, smartd, fail2ban,
  Tailscale, users and SSH stay shared.
- Bluetooth stays shared (harmless on workers, keeps the file simple).

### 3. Disk layout on the workers

Same btrfs scheme as `homelab-0` (ESP + btrfs with `rootfs`, `home`, `nix`
subvolumes), from the one shared disko file with `device = meta.disk`.

Longhorn replicas are sparse files with random 4K writes; on a CoW
filesystem that doubles or triples the physical writes (measured ~2.4x
amplification on `homelab-0`). btrfs only honours `nodatacow` for the whole
filesystem, so the fix is the `C` attribute on the Longhorn directory, set
by a tmpfiles rule on every node:

```
d /var/lib/longhorn 0700 root root -
h /var/lib/longhorn - - - - +C
```

New files under that directory inherit no-CoW (no checksums, no compression
for them; Longhorn carries its own replica integrity). Existing replica
files on `homelab-0` keep CoW; they get the benefit when a volume is
rebuilt or a second replica is created on a worker.

Device: `/dev/nvme0n1` is the expected disk in a 5080 Micro. `lsblk` on the
installer must confirm this before `nixos-anywhere` runs (disko formats the
device unconditionally).

### 4. Networking

- IPs come from DHCP reservations on the router (`.152`, `.153`), the same
  mechanism as `.151`. No static addressing in NixOS.
- Tailscale on all nodes. Pre-install check: the current auth key must be
  reusable (Tailscale admin console → Settings → Keys). If it is single-use,
  mint a new reusable, pre-authorized key tagged `tag:k8s` and update the
  `tailscale-auth-key` secret first. A node that fails `tailscale up` still
  joins k3s; it only loses MagicDNS reachability for the rebuild workflow.
- Flannel VXLAN (k3s default) over the LAN; nothing to configure.
- MetalLB speakers run on every node (DaemonSet); L2 announcements keep
  working from whichever node holds the lease.

### 5. Storage

- Longhorn's `defaultClassReplicaCount` goes from 1 to **2** once both
  workers are `Ready` (an earlier change would leave new volumes degraded).
  Three replicas would consume too much of the 256 GB disks.
- Existing volumes are raised to 2 replicas afterwards, one at a time, via
  the Longhorn UI or `kubectl patch volumes.longhorn.io`. 86 GB of extra
  replica space lands on the workers (~200 GB usable each).
- `storage-minimal-available-percentage` stays at 25.
- `node-down-pod-deletion-policy` changes from `do-nothing` to
  `delete-both-statefulset-and-deployment-pod`, so a pod on a dead worker is
  rescheduled instead of stuck `Terminating` forever.

### 6. Workload placement

Workers register with `thomvandev.in/role=worker` (`services.k3s.nodeLabel`).
The kubelet refuses to self-assign anything under `node-role.kubernetes.io/`,
so that label is added once by hand after the join, purely so
`kubectl get nodes` shows `worker` in ROLES; manifests select on the
`thomvandev.in` label. `homelab-0` keeps the
`node-role.kubernetes.io/control-plane` label k3s already sets.

Three placement rules, each a Helm named template in
`apps/templates/_placement.tpl` so every manifest change is a one-line
`include`:

| Template | Mechanism | Applied to |
|---|---|---|
| `placement.homelab0` | `nodeSelector: kubernetes.io/hostname: homelab-0` (required) | home-assistant (chart `nodeSelector`), matter-server, unifi + unifi-mongo, docker-registry, closet minio, van-mierlo minio |
| `placement.workersOnly` | `nodeSelector: thomvandev.in/role: worker` (required) | gitlab-runner and gitlab-runner-swiss-rounds job pods (`[runners.kubernetes.node_selector]`), ARC `RunnerDeployment`s |
| `placement.preferWorkers` | `nodeAffinity.preferredDuringScheduling`, weight 100 on the worker label | closet server/web/ai, limitless-tournament-decks, pokemon-bot (all Deployments and the rabbitmq StatefulSet), pokemon-index, scraper, slowpoke-bingo (+ sync CronJob), swiss-rounds (+ stg), flaresolverr, reposilite, end-of-year, pokemon-ai, van-mierlo backend/frontend |

Why each pin:

- **home-assistant + matter-server**: both `hostNetwork`; HA reaches the
  Matter server on `localhost:5580`; Matter hard-codes `PRIMARY_INTERFACE=enp1s0`
  and proxies the host's Bluetooth over `/run/dbus`. They move together or not
  at all, and they don't move.
- **unifi**: `hostNetwork`; every AP informs to `192.168.178.151:8080`.
  Moving it re-homes the APs.
- **docker-registry**: static hostPath PV at `/mnt/data/registry`.
- **minio (closet, van-mierlo)**: `quay.io/minio/minio:latest` with
  `IfNotPresent`; the only copy of that image is in `homelab-0`'s containerd
  cache (PR #613). Replacing it with a pullable tag is a separate change.

Why workers-only for CI: a job pod that cannot find a worker waits
(`poll_timeout = 600`) and then fails, rather than landing on the control
plane. That is the intended failure mode after the load-218 incident.

Why preferred rather than required for own apps: if both workers are
down, the apps still run on `homelab-0`, degraded but up.

Not touched: ArgoCD, cert-manager, MetalLB, ingress-nginx, Tailscale
operator, cloudflare-tunnel, postgres, sharry, nginx-reverse-proxy, echo,
Longhorn. The scheduler spreads them; with `homelab-0` at 96% CPU requests
they drift to the workers on their next restart.

ingress-nginx runs with `externalTrafficPolicy: Local`; MetalLB's L2 lease
follows the node that runs the controller pod, so it keeps working wherever
that pod lands.

No taints on `homelab-0`: tainting it would need tolerations on every
DaemonSet and system chart for no gain.

Expected request budget after the move (CPU): about 2.2 of the 3.9 cores
requested on `homelab-0` belong to apps that get `preferWorkers` or
`workersOnly`, leaving `homelab-0` around 45% requested.

### 7. Rollout order

1. Merge the NixOS refactor (homelab-0 closure unchanged; CI rebuilds it).
2. Router: DHCP reservations for `.152` / `.153` (owner does this).
3. Per worker: boot the NixOS installer, confirm the disk, seed the host key,
   add the host's age key to `nixos/.sops.yaml`, `sops updatekeys`,
   `nixos-anywhere --flake .#homelab-N`.
4. Node appears `Ready`; Longhorn and MetalLB DaemonSets roll out; verify
   `kubectl get nodes -o wide` and the Longhorn node page.
5. Add `homelab-1`/`homelab-2` to the rebuild workflow matrix.
6. Apply the storage changes (section 5) and the placement changes
   (section 6) through ArgoCD, one PR each.
7. Raise existing volumes to 2 replicas.

### 8. Out of scope

- HA control plane (three etcd members). Adding servers later is a
  supported k3s operation if the single control plane becomes a problem.
- Moving Home Assistant, UniFi or the Matter server off `homelab-0`.
- Replacing `homelab-0`'s worn SSD.

## Open questions for the owner

1. Which disk does `lsblk` show on the 5080s (`nvme0n1` or `sda`)? Decides
   the disko `device`.
2. Is the current Tailscale auth key reusable? If not, a new one is needed
   before the first install.
