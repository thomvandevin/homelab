# Worker Nodes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `homelab-1` and `homelab-2` (Dell OptiPlex 5080 Micro) as k3s agents, keep `homelab-0` as the only control plane, and move CI job pods and own-built applications onto the workers.

**Architecture:** One shared NixOS `configuration.nix` with a role switch (`server` / `agent`) driven by a `nodes` attrset in `flake.nix`; per-machine hardware files under `nixos/hosts/`; one shared disko file parameterised by disk. Workload placement is expressed as three Helm named templates in `apps/templates/_placement.tpl` and applied per manifest. Storage stays Longhorn, raised to two replicas once both workers are in.

**Tech Stack:** NixOS (nixos-unstable, flakes, disko, sops-nix), k3s v1.36, ArgoCD app-of-apps rendered with Helm, Longhorn 1.12, GitHub Actions (ARC) and GitLab runners.

**Spec:** `docs/superpowers/specs/2026-10-05-multi-node-cluster-design.md`

## Global Constraints

- `homelab-0` keeps `role = "server"`, `clusterInit = true`, and the flags `--write-kubeconfig-mode "0644" --disable servicelb --disable traefik --disable local-storage`.
- Agents: `serverAddr = "https://192.168.178.151:6443"`, `tokenFile = config.sops.secrets.k3s-token.path`, label `thomvandev.in/role=worker`.
- Worker disk is `/dev/nvme0n1`; the installer's `lsblk` must confirm this before `nixos-anywhere` runs.
- IPs `.152` / `.153` come from router DHCP reservations, not NixOS.
- PRs are public: terse changelogs, no IPs, MACs, hostnames of other devices, serials, or secrets in PR text.
- No `Co-Authored-By` lines or AI references in commits.
- No emdashes anywhere.
- Comments only where the code is non-obvious; explain the "why" that the code cannot.
- The placement PR (Task 5) and the Longhorn PR (Task 7) may only merge once both workers are `Ready`. Merging `workersOnly` before that would leave every CI job pod unschedulable.

## Review Focus

1. `homelab-0`'s system closure after Task 1 must be byte-identical to the one it runs now; a drift there means the refactor changed the production host. Test: Task 1 step 6.
2. An agent must never receive a server-only flag (`--write-kubeconfig-mode`, `--disable`, `--cluster-init`); k3s refuses to start on unknown flags. Test: Task 2 step 4.
3. `sops` must decrypt `secrets.yaml` with the personal key and with each new host key, or the first boot of a worker fails activation. Test: Task 3 steps 7 and 8.
4. `kubectl get nodes` must show the `worker` role on the new nodes, or every `nodeSelector` in Task 5 silently matches nothing and CI job pods hang. Test: Task 6 step 6.
5. Pinned pods (HA, matter, unifi, registry, both MinIO) must render with `kubernetes.io/hostname: homelab-0` and nothing else must. Test: Task 5 step 8.

---

### Task 1: Per-host NixOS layout, homelab-0 unchanged

**Files:**
- Move: `nixos/hardware-configuration.nix` → `nixos/hosts/homelab-0.nix`
- Modify: `nixos/flake.nix`
- Modify: `nixos/disko-configuration.nix:1-6`
- Modify: `nixos/README.md:16`

**Interfaces:**
- Produces: `meta = { hostname; role; disk; }` as `specialArgs` for every module. `meta.role` is `"server"` or `"agent"`. `meta.disk` is the block device path.

- [ ] **Step 1: Record the closure homelab-0 runs now**

```bash
ssh homelab@192.168.178.151 'readlink /run/current-system'
```
Keep the printed `/nix/store/...-nixos-system-homelab-0-...` path; Task 1 must reproduce it exactly.

- [ ] **Step 2: Move the hardware file**

```bash
cd nixos
git mv hardware-configuration.nix hosts/homelab-0.nix
```

- [ ] **Step 3: Rewrite `flake.nix`**

Replace the whole `outputs` body:

```nix
  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
      ...
    }@inputs:
    let
      nodes = {
        homelab-0 = {
          role = "server";
          disk = "/dev/sda";
          hardware = ./hosts/homelab-0.nix;
        };
        homelab-1 = {
          role = "agent";
          disk = "/dev/nvme0n1";
          hardware = ./hosts/optiplex-5080-micro.nix;
        };
        homelab-2 = {
          role = "agent";
          disk = "/dev/nvme0n1";
          hardware = ./hosts/optiplex-5080-micro.nix;
        };
      };
    in
    {
      nixosConfigurations = builtins.mapAttrs (
        name: node:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            meta = {
              hostname = name;
              inherit (node) role disk;
            };
          };
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            node.hardware
            ./disko-configuration.nix
            ./configuration.nix
          ];
        }
      ) nodes;
    };
```

- [ ] **Step 4: Parameterise the disko device**

`nixos/disko-configuration.nix` starts with `{` on line 1. Change the head of the file to:

```nix
{ meta, ... }:
{
  disko.devices = {
    disk = {
      vdb = {
        type = "disk";
        device = meta.disk;
```

Everything below `device` stays as is.

- [ ] **Step 5: Create a placeholder worker hardware file so the flake evaluates**

`nixos/hosts/optiplex-5080-micro.nix`:

```nix
{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "usbhid"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];
  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
```

- [ ] **Step 6: Verify homelab-0 builds to the identical store path**

Push the branch, then build on the host (it is the only x86_64-linux builder):

```bash
git add -A nixos && git commit -q -m "chore(nixos): per-host hardware files and node table" && git push -u origin feat/worker-nodes
ssh homelab@192.168.178.151 'nixos-rebuild build --flake "github:thomvandevin/homelab?dir=nixos&ref=feat/worker-nodes#homelab-0" >/dev/null 2>&1 && readlink result && readlink /run/current-system'
```
Expected: the two printed paths are identical. If they differ, run
`ssh homelab@192.168.178.151 'nix store diff-closures /run/current-system ./result'`
and fix whatever changed before continuing.

- [ ] **Step 7: Confirm the agents evaluate**

```bash
ssh homelab@192.168.178.151 'nixos-rebuild build --flake "github:thomvandevin/homelab?dir=nixos&ref=feat/worker-nodes#homelab-1" >/dev/null 2>&1 && echo ok'
```
Expected: `ok`. (At this point homelab-1 still gets the server role; Task 2 fixes that.)

- [ ] **Step 8: Update the README path**

In `nixos/README.md` the "Deploy with NixOS Anywhere" section references `disko-configuration.nix`; leave it. Add under "Building NixOS flake":

```markdown
Hosts are listed in `flake.nix` (`nodes`); each entry names its role, disk and
hardware file under `hosts/`.
```

Commit:
```bash
git add nixos/README.md && git commit -q -m "docs(nixos): point at the node table"
```

---

### Task 2: Role-dependent k3s configuration

**Files:**
- Modify: `nixos/configuration.nix:88-142` (webhook cleanup service and `services.k3s`)
- Modify: `nixos/configuration.nix:81-84` (tmpfiles rules)

**Interfaces:**
- Consumes: `meta.role` from Task 1.
- Produces: agents labelled `thomvandev.in/role=worker`; `/var/lib/longhorn` with the `C` attribute on every node.

- [ ] **Step 1: Replace the k3s block**

Replace the existing `services.k3s = { ... };` (the block containing `role = "server";` and the `extraFlags` list) with:

```nix
  services.k3s = lib.mkMerge [
    {
      enable = true;
      role = meta.role;
    }
    (lib.mkIf (meta.role == "server") {
      clusterInit = true;
      extraFlags = toString [
        "--write-kubeconfig-mode \"0644\""
        "--disable servicelb"
        "--disable traefik"
        "--disable local-storage"
      ];
    })
    (lib.mkIf (meta.role == "agent") {
      serverAddr = "https://192.168.178.151:6443";
      tokenFile = config.sops.secrets.k3s-token.path;
      nodeLabel = [ "thomvandev.in/role=worker" ];
      # drain this node's pods on reboot or poweroff instead of letting them
      # time out on the control plane
      gracefulNodeShutdown.enable = true;
    })
  ];
```

Note: the old block passed `--cluster-init` twice (once via `clusterInit`, once in `extraFlags`). The new block passes it once; the flag is idempotent and this is the only ExecStart change on `homelab-0`.

- [ ] **Step 2: Make the webhook cleanup server-only**

Change the first line of that service from
```nix
  systemd.services.k3s-longhorn-webhook-cleanup = {
```
to
```nix
  systemd.services.k3s-longhorn-webhook-cleanup = lib.mkIf (meta.role == "server") {
```

- [ ] **Step 3: Add the Longhorn no-CoW attribute**

Replace
```nix
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];
```
with
```nix
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
    # Longhorn replicas are sparse files under random 4K writes; btrfs CoW
    # multiplies the physical writes, and nodatacow is filesystem-wide, so the
    # attribute goes on the directory and new replica files inherit it
    "d /var/lib/longhorn 0700 root root -"
    "h /var/lib/longhorn - - - - +C"
  ];
```

- [ ] **Step 4: Verify the rendered ExecStart lines**

```bash
cd nixos
for h in homelab-0 homelab-1; do
  echo "== $h"
  nix eval --raw --extra-experimental-features "nix-command flakes" \
    ".#nixosConfigurations.$h.config.systemd.services.k3s.serviceConfig.ExecStart"
  echo
done
```
Expected for `homelab-0`: one `--cluster-init`, the four server flags, no `--server`, no `--token-file`.
Expected for `homelab-1`: `k3s agent`, `--server https://192.168.178.151:6443`, `--token-file /run/secrets/k3s-token`, `--node-label thomvandev.in/role=worker`, and none of the server flags.

Also:
```bash
nix eval --json --extra-experimental-features "nix-command flakes" \
  ".#nixosConfigurations.homelab-1.config.systemd.services" --apply 'builtins.hasAttr "k3s-longhorn-webhook-cleanup"'
```
Expected: `false`. Same command with `homelab-0`: `true`.

- [ ] **Step 5: Build both roles on the host**

```bash
git add nixos && git commit -q -m "feat(nixos): agent role for worker nodes" && git push
ssh homelab@192.168.178.151 'for h in homelab-0 homelab-1; do nixos-rebuild build --flake "github:thomvandevin/homelab?dir=nixos&ref=feat/worker-nodes#$h" >/dev/null 2>&1 && echo "$h ok"; done'
```
Expected: `homelab-0 ok`, `homelab-1 ok`.

---

### Task 3: Secrets for the new hosts

**Files:**
- Move: `nixos/extra-files/etc/` → `nixos/extra-files/homelab-0/etc/` (gitignored, local only)
- Create: `nixos/extra-files/homelab-1/etc/ssh/ssh_host_ed25519_key{,.pub}`, same for `homelab-2` (gitignored)
- Modify: `nixos/.sops.yaml`
- Modify: `nixos/secrets.yaml` (re-encrypted; `k3s-token` replaced)
- Modify: `nixos/README.md` (Secrets and Deploy sections)

**Interfaces:**
- Produces: `secrets.yaml` decryptable by the personal key, `homelab-0`, `homelab-1` and `homelab-2`; `k3s-token` equal to the live server node token.

- [ ] **Step 1: Re-home homelab-0's pre-seeded key**

```bash
cd nixos
mkdir -p extra-files/homelab-0
git mv -k extra-files/etc extra-files/homelab-0/etc 2>/dev/null || mv extra-files/etc extra-files/homelab-0/etc
ls extra-files/homelab-0/etc/ssh
```
Expected: `ssh_host_ed25519_key  ssh_host_ed25519_key.pub`.

- [ ] **Step 2: Generate host keys for the workers**

```bash
for h in homelab-1 homelab-2; do
  mkdir -p extra-files/$h/etc/ssh
  ssh-keygen -t ed25519 -N "" -C "root@$h" -f extra-files/$h/etc/ssh/ssh_host_ed25519_key
  chmod 600 extra-files/$h/etc/ssh/ssh_host_ed25519_key
  echo "$h: $(nix run --extra-experimental-features 'nix-command flakes' nixpkgs#ssh-to-age -- -i extra-files/$h/etc/ssh/ssh_host_ed25519_key.pub)"
done
```
Expected: two `age1...` keys printed.

- [ ] **Step 3: Add the keys to `.sops.yaml`**

`nixos/.sops.yaml` becomes (personal key first, then the three hosts in order):

```yaml
creation_rules:
  # Personal key (../key.txt) first so secrets stay decryptable when a host is
  # rebuilt; host keys below are derived from each machine's SSH host key and
  # change on every reinstall.
  - age: >-
      age13w8ryx3k4ak47n7cfmccyachptt5lr3v97ndfc87ms02x7yj4saqp3qhal,
      age1l9072xnffr34m9hf5nzlls0fad004mkx7xckwt760r9gk5ayjg6sgs6mvj,
      <homelab-1 age key>,
      <homelab-2 age key>
```

- [ ] **Step 4: Decrypt, replace the token, re-encrypt**

The live token is the one agents must present. Never echo it.

```bash
SOPS_AGE_KEY_FILE=../key.txt sops --decrypt secrets.yaml > secrets.yaml.dec
ssh homelab@192.168.178.151 'sudo cat /var/lib/rancher/k3s/server/node-token' | tr -d '\n' > /tmp/node-token
python3 - <<'EOF'
import re
tok = open('/tmp/node-token').read()
s = open('secrets.yaml.dec').read()
s2 = re.sub(r'^k3s-token:.*$', 'k3s-token: ' + tok, s, flags=re.M)
assert s2 != s
open('secrets.yaml.dec', 'w').write(s2)
EOF
rm /tmp/node-token
sops --encrypt --input-type yaml --output-type yaml secrets.yaml.dec > secrets.yaml
```

- [ ] **Step 5: Verify the token matches the server**

```bash
a=$(SOPS_AGE_KEY_FILE=../key.txt sops --decrypt --extract '["k3s-token"]' secrets.yaml | shasum -a 256 | cut -c1-16)
b=$(ssh homelab@192.168.178.151 'sudo cat /var/lib/rancher/k3s/server/node-token' | tr -d '\n' | shasum -a 256 | cut -c1-16)
[ "$a" = "$b" ] && echo match || echo MISMATCH
```
Expected: `match`.

- [ ] **Step 6: Verify every recipient can decrypt**

```bash
SOPS_AGE_KEY_FILE=../key.txt sops --decrypt secrets.yaml >/dev/null && echo personal-ok
for h in homelab-1 homelab-2; do
  SOPS_AGE_KEY=$(nix run --extra-experimental-features 'nix-command flakes' nixpkgs#ssh-to-age -- -private-key -i extra-files/$h/etc/ssh/ssh_host_ed25519_key) \
    sops --decrypt secrets.yaml >/dev/null && echo "$h-ok"
done
```
Expected: `personal-ok`, `homelab-1-ok`, `homelab-2-ok`.

- [ ] **Step 7: Verify the Tailscale key is reusable (owner)**

Tailscale admin console → Settings → Keys: the key minted 2026-08-26 (tag `tag:k8s`) must show **Reusable**. If it does not, mint a new one (reusable, pre-authorized, tag `tag:k8s`, 90 days), put it in `secrets.yaml.dec` under `tailscale-auth-key`, and re-run steps 4's encrypt line and step 6.

- [ ] **Step 8: Update `nixos/README.md`**

In "Deploy with NixOS Anywhere" replace the command with:

```sh
nix run github:nix-community/nixos-anywhere \
--extra-experimental-features "nix-command flakes" \
-- --flake '.#homelab-1' \
   --build-on remote \
   --extra-files ./extra-files/homelab-1 \
   --target-host nixos@host
```

In "Secrets" replace the `mkdir`/`ssh-keygen` lines with:

```sh
mkdir -p extra-files/homelab-1/etc/ssh
ssh-keygen -t ed25519 -N "" -C "root@homelab-1" -f extra-files/homelab-1/etc/ssh/ssh_host_ed25519_key
chmod 600 extra-files/homelab-1/etc/ssh/ssh_host_ed25519_key

nix run nixpkgs#ssh-to-age -- -i extra-files/homelab-1/etc/ssh/ssh_host_ed25519_key.pub
```

and add after the `sops --encrypt` line:

```markdown
`k3s-token` must equal the control plane's
`/var/lib/rancher/k3s/server/node-token`; agents present it to join.
```

- [ ] **Step 9: Commit**

```bash
git add .sops.yaml secrets.yaml README.md
git status --short   # extra-files/ and secrets.yaml.dec must NOT appear
git commit -q -m "chore(nixos): sops recipients and join token for the worker nodes"
git push
```

---

### Task 4: Pull request for the NixOS side

**Files:** none new.

- [ ] **Step 1: Open the PR**

```bash
gh pr create --base main --head feat/worker-nodes --title "feat(nixos): worker node role and per-host layout" --body "$(cat <<'EOF'
- per-host hardware files and a node table in the flake
- agent role: joins the control plane, carries the worker label, drains on shutdown
- Longhorn data directory gets the no-CoW attribute
- sops recipients and join token for the two new hosts

Control-plane closure unchanged apart from the deduplicated cluster-init flag.
EOF
)"
```

- [ ] **Step 2: Merge once CI is green and the owner has reviewed**

The `nixos rebuild` workflow builds and switches `homelab-0`. Verify afterwards:

```bash
ssh homelab@192.168.178.151 'systemctl is-active k3s; lsattr -d /var/lib/longhorn'
```
Expected: `active` and a `C` in the attribute column.

---

### Task 5: Workload placement in `apps/`

**Files:**
- Create: `apps/templates/_placement.tpl`
- Modify: `apps/templates/helm-homeassistant.yaml`, `app-matter-server.yaml`, `app-unifi.yaml`, `docker-registry.yaml`, `app-closet.yaml`, `app-van-mierlo.yaml`, `helm-gitlab-runner.yaml`, `helm-gitlab-runner-swiss-rounds.yaml`, `arc-runner.yaml`, `app-limitless-tournament-decks.yaml`, `app-pokemon-bot.yaml`, `app-pokemon-index.yaml`, `app-scraper.yaml`, `app-slowpoke-bingo.yaml`, `app-swiss-rounds.yaml`, `app-flaresolverr.yaml`, `app-maven-proxy.yaml`, `app-end-of-year.yaml`, `app-pokemon-ai.yaml`
- Create (scratch, not committed): placement check script

**Interfaces:**
- Produces: named templates `placement.homelab0`, `placement.workersOnly`, `placement.preferWorkers`, each rendering a pod-spec fragment.

**Do not merge before both workers are `Ready` (Task 6).**

- [ ] **Step 1: Write the check script**

Scratch file `check-placement.py` (anywhere outside the repo):

```python
import subprocess, sys, yaml

PIN = {"home-assistant", "matter-server", "unifi", "unifi-mongo", "registry", "minio"}
WORKERS_ONLY = {"homelab-runner", "homelab-media-runner"}
PREFER = {"closet-server", "closet-web", "closet-ai", "limitless-tournament-decks",
          "rabbitmq", "dashboard-backend", "portal-backend", "portal-frontend",
          "dashboard-frontend", "scraper-backend", "notifications-backend",
          "checkout-backend", "fingerprint-fetcher", "pokemon-index", "scraper",
          "slowpoke-bingo", "slowpoke-bingo-sync", "swiss-rounds", "swiss-rounds-stg",
          "flaresolverr", "reposilite", "end-of-year", "postgresql", "chat-api",
          "card-api", "chat-ui", "mcp-server", "showcase-ui", "backend", "frontend"}

out = subprocess.run(["helm", "template", "apps", "apps/", "--values", sys.argv[1]],
                     capture_output=True, text=True, check=True).stdout
seen, bad = set(), []
for doc in yaml.safe_load_all(out):
    if not doc or doc.get("kind") not in ("Deployment", "StatefulSet", "CronJob", "RunnerDeployment"):
        continue
    name = doc["metadata"]["name"]
    spec = doc["spec"]
    pod = (spec["jobTemplate"]["spec"]["template"]["spec"] if doc["kind"] == "CronJob"
           else spec["template"]["spec"])
    sel = pod.get("nodeSelector") or {}
    aff = (((pod.get("affinity") or {}).get("nodeAffinity") or {})
           .get("preferredDuringSchedulingIgnoredDuringExecution") or [])
    seen.add(name)
    if name in PIN and sel != {"kubernetes.io/hostname": "homelab-0"}: bad.append((name, "expected pin"))
    elif name in WORKERS_ONLY and sel != {"thomvandev.in/role": "worker"}: bad.append((name, "expected workersOnly"))
    elif name in PREFER and not aff: bad.append((name, "expected preferWorkers"))
    elif name not in PIN | WORKERS_ONLY | PREFER and (sel or aff): bad.append((name, "unexpected placement"))
missing = (PIN | WORKERS_ONLY | PREFER) - seen
print("missing:", sorted(missing)) if missing else None
for b in bad: print("BAD", *b)
sys.exit(1 if bad or missing else 0)
```

(`home-assistant` is a Helm chart; its StatefulSet is not in `helm template` output. Check it separately in step 7.)

- [ ] **Step 2: Run it to see the current failures**

```bash
cd /Users/thomvandevin/Projects/thomvandevin/homelab
python3 check-placement.py <(SOPS_AGE_KEY_FILE=key.txt sops --decrypt apps/secrets.yaml)
```
Expected: exit 1, one `BAD ... expected ...` line per workload in the three sets (except `home-assistant`, which reports `missing`; remove it from `PIN` in the script, it is covered by step 7).

- [ ] **Step 3: Create the named templates**

`apps/templates/_placement.tpl`:

```yaml
{{/*
Pod-spec fragments for node placement. homelab-0 is the control plane and the
only host with the Zigbee/Bluetooth hardware, the UniFi inform address and the
registry hostPath; workers carry thomvandev.in/role=worker.
*/}}

{{- define "placement.homelab0" -}}
nodeSelector:
  kubernetes.io/hostname: homelab-0
{{- end -}}

{{- define "placement.workersOnly" -}}
nodeSelector:
  thomvandev.in/role: worker
{{- end -}}

{{- define "placement.preferWorkers" -}}
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: thomvandev.in/role
              operator: In
              values: ["worker"]
{{- end -}}
```

- [ ] **Step 4: Apply the includes to plain manifests**

In each Deployment / StatefulSet pod spec (`spec.template.spec`) and each CronJob pod spec (`spec.jobTemplate.spec.template.spec`) listed below, add the include as the first key of that `spec:` block, indented to match its siblings (6 spaces for Deployments, 10 for CronJobs):

```yaml
    spec:
      {{- include "placement.preferWorkers" . | nindent 6 }}
      containers:
```

| Include | Files and workloads |
|---|---|
| `placement.homelab0` | `app-matter-server.yaml` matter-server; `app-unifi.yaml` unifi, unifi-mongo; `docker-registry.yaml` registry; `app-closet.yaml` minio; `app-van-mierlo.yaml` minio |
| `placement.preferWorkers` | `app-closet.yaml` closet-server, closet-web, closet-ai; `app-limitless-tournament-decks.yaml` limitless-tournament-decks (not its CronJobs); `app-pokemon-bot.yaml` rabbitmq and all nine Deployments; `app-pokemon-index.yaml`; `app-scraper.yaml` scraper (not its CronJobs); `app-slowpoke-bingo.yaml` slowpoke-bingo, slowpoke-bingo-sync CronJob; `app-swiss-rounds.yaml` both; `app-flaresolverr.yaml`; `app-maven-proxy.yaml` reposilite; `app-end-of-year.yaml`; `app-pokemon-ai.yaml` all six; `app-van-mierlo.yaml` backend, frontend |

- [ ] **Step 5: ARC runners**

`apps/templates/arc-runner.yaml`, both `RunnerDeployment`s:

```yaml
  template:
    spec:
      repository: thomvandevin/homelab
      {{- include "placement.workersOnly" . | nindent 6 }}
```

- [ ] **Step 6: GitLab runner job pods**

In `helm-gitlab-runner.yaml`, inside `[runners.kubernetes]` after `poll_timeout = 600`, and in `helm-gitlab-runner-swiss-rounds.yaml` after `helper_memory_request = "128Mi"`, add:

```toml
                # CI jobs never run on the control plane; a job waits for a worker
                # (poll_timeout) rather than landing next to etcd
                [runners.kubernetes.node_selector]
                  "thomvandev.in/role" = "worker"
```

(Indentation: the `[runners.kubernetes.node_selector]` header sits at the same column as `[runners.kubernetes]`'s keys, i.e. 16 spaces; its key at 18.)

- [ ] **Step 7: Home Assistant chart**

In `helm-homeassistant.yaml` `valuesObject`, next to `hostNetwork: true`:

```yaml
        nodeSelector:
          kubernetes.io/hostname: homelab-0
```

Verify the chart honours it:

```bash
helm template ha oci://ghcr.io/pajikos/home-assistant --version $(grep targetRevision apps/templates/helm-homeassistant.yaml | awk '{print $2}') \
  --set hostNetwork=true --set 'nodeSelector.kubernetes\.io/hostname=homelab-0' | grep -A1 nodeSelector
```
Expected: `kubernetes.io/hostname: homelab-0` under `nodeSelector`. (If the chart lives at a different registry, use the `repoURL` from the template.)

- [ ] **Step 8: Run the check script**

```bash
python3 check-placement.py <(SOPS_AGE_KEY_FILE=key.txt sops --decrypt apps/secrets.yaml) && echo PLACEMENT OK
```
Expected: `PLACEMENT OK`, no `BAD`, no `missing`.

- [ ] **Step 9: Render the runner configs**

```bash
helm template apps apps/ --values <(SOPS_AGE_KEY_FILE=key.txt sops --decrypt apps/secrets.yaml) | grep -B1 -A1 'node_selector'
```
Expected: two `[runners.kubernetes.node_selector]` headers each followed by the worker label line.

- [ ] **Step 10: Commit on a new branch**

```bash
git checkout -b feat/worker-placement main
git add apps/templates
git commit -q -m "feat(apps): place CI and own apps on the worker nodes"
git push -u origin feat/worker-placement
```
Open the PR but leave it unmerged until Task 6 is complete:

```bash
gh pr create --base main --head feat/worker-placement --title "feat(apps): place CI and own apps on the worker nodes" --body "$(cat <<'EOF'
- hardware-bound apps pinned to the control plane
- CI job pods and ARC runners restricted to workers
- own applications prefer workers, fall back to the control plane

Merge after both workers are Ready.
EOF
)"
```

---

### Task 6: Install the two workers (runbook)

Performed with the owner present, one node at a time. Prerequisite: Task 4 merged and switched on `homelab-0`; router reservations for `.152` and `.153` in place.

- [ ] **Step 1: Boot the installer**

Write the NixOS minimal ISO (x86_64) to a USB stick, boot the 5080 from it (F12 → USB). On the installer console:

```bash
sudo -i
mkdir -p /home/nixos/.ssh
curl -fsSL https://github.com/thomvandevin.keys > /home/nixos/.ssh/authorized_keys
chown -R nixos:users /home/nixos/.ssh
ip -4 -br a | grep -v lo
lsblk -d -o NAME,SIZE,MODEL
```
Note the DHCP address (it will not be `.152` yet unless the reservation matched the MAC already) and confirm the disk is `nvme0n1`. If it is `sda`, change `disk` for that host in `nixos/flake.nix` before continuing.

- [ ] **Step 2: Run nixos-anywhere**

From the Mac, in `nixos/`, on `main` after Task 4:

```bash
nix run github:nix-community/nixos-anywhere \
  --extra-experimental-features "nix-command flakes" \
  -- --flake '.#homelab-1' \
     --build-on remote \
     --extra-files ./extra-files/homelab-1 \
     --target-host nixos@<installer-ip>
```
Expected: disko partitions `/dev/nvme0n1`, the system builds on the target, the machine reboots into NixOS.

- [ ] **Step 3: First boot checks on the worker**

```bash
ssh homelab@192.168.178.152 'hostname; systemctl is-active k3s tailscaled; sudo journalctl -u k3s --no-pager -n 5; tailscale status --self | head -1; lsattr -d /var/lib/longhorn'
```
Expected: `homelab-1`, `active active`, k3s log lines mentioning the server address with no auth errors, a tailnet address, a `C` attribute.

If k3s logs `token` or `401`: the `k3s-token` secret does not match the server; redo Task 3 step 4.
If `tailscale status` shows `NeedsLogin`: the auth key was single-use; mint a reusable one (Task 3 step 7) and run `sudo tailscale up --authkey <key>` on the node once.

- [ ] **Step 4: Node joined**

```bash
ssh homelab@192.168.178.151 'sudo k3s kubectl get nodes -o wide'
```
Expected: `homelab-1 Ready worker` with internal IP `192.168.178.152`.

- [ ] **Step 5: DaemonSets rolled out**

```bash
ssh homelab@192.168.178.151 'sudo k3s kubectl get pods -A -o wide --field-selector spec.nodeName=homelab-1'
```
Expected: longhorn-manager, longhorn-csi-plugin, engine-image, metallb speaker and kube-flannel-less svclb absent (servicelb disabled) all `Running`.

```bash
ssh homelab@192.168.178.151 'sudo k3s kubectl -n longhorn-system get nodes.longhorn.io homelab-1 -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status} {.status.diskStatus}"'
```
Expected: `True` and a disk entry with roughly 200 GB available.

- [ ] **Step 6: Label present**

```bash
ssh homelab@192.168.178.151 'sudo k3s kubectl get node homelab-1 --show-labels | tr , "\n" | grep worker'
```
Expected: `thomvandev.in/role=worker`.

- [ ] **Step 7: Repeat steps 1 to 6 for homelab-2** (`.#homelab-2`, `extra-files/homelab-2`, `192.168.178.153`).

- [ ] **Step 8: Add the hosts to the rebuild workflow**

`.github/workflows/rebuild-nixos.yaml`, both matrices:

```yaml
        host: ["homelab-0", "homelab-1", "homelab-2"]
```

Also update the root `README.md` node list to:

```markdown
- homelab-0 (192.168.178.151) control plane
- homelab-1 (192.168.178.152) worker
- homelab-2 (192.168.178.153) worker
```

```bash
git checkout -b chore/ci-worker-hosts main
git add .github/workflows/rebuild-nixos.yaml README.md
git commit -q -m "ci: rebuild the worker nodes too"
git push -u origin chore/ci-worker-hosts
gh pr create --fill --base main
```
Merge it; the workflow must go green for all three hosts.

---

### Task 7: Storage and placement after both workers are in

- [ ] **Step 1: Merge the placement PR (Task 5)**

Watch it land:
```bash
ssh homelab@192.168.178.151 'sudo k3s kubectl get pods -A -o wide | grep -E "pokemon-bot|closet|scraper|slowpoke|limitless|swiss|flaresolverr|maven-proxy|gitlab-runner|default " | awk "{print \$1, \$2, \$8}"'
```
Expected: own-app pods and both runner managers on `homelab-1`/`homelab-2` after their rollout; `minio` pods still on `homelab-0`.

- [ ] **Step 2: Longhorn settings**

`apps/templates/helm-longhorn.yaml`:

```yaml
        persistence:
          # Three nodes with replica-soft-anti-affinity off: two replicas fit the
          # 256 GB worker disks, three would not
          defaultClassReplicaCount: 2
```
and under `defaultSettings`:
```yaml
          # a pod whose node died is rescheduled instead of staying Terminating
          nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod
```

```bash
git checkout -b feat/longhorn-two-replicas main
git add apps/templates/helm-longhorn.yaml
git commit -q -m "feat(longhorn): two replicas by default, reschedule pods off dead nodes"
git push -u origin feat/longhorn-two-replicas
gh pr create --fill --base main
```

- [ ] **Step 3: Raise existing volumes, one at a time**

```bash
ssh homelab@192.168.178.151 'K="sudo k3s kubectl -n longhorn-system"; for v in $($K get volumes.longhorn.io -o name); do $K patch $v --type merge -p "{\"spec\":{\"numberOfReplicas\":2}}"; sleep 60; $K get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness --no-headers | grep -v healthy || true; done'
```
Expected: each volume reports `degraded` while the second replica builds, then `healthy`. Leave the `van-mierlo` volume (detached) for last or skip it.

- [ ] **Step 4: Final state**

```bash
ssh homelab@192.168.178.151 'sudo k3s kubectl describe nodes | grep -A5 "Allocated resources" | grep -E "cpu|memory"'
```
Expected: `homelab-0` CPU requests well under 60%; both workers with requests but headroom.

Update the memory file `project_nixos_reboot_pending.md` or add a new project memory noting the three-node layout, Longhorn replica count 2 and the worker label.
