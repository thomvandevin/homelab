# AdGuard DHCP Takeover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move IPv4 DHCP from the Ziggo modem to AdGuard Home on homelab-0, so every LAN device gets AdGuard (then 9.9.9.9) as DNS, without the cluster depending on its own DHCP.

**Architecture:** The three nodes get static IPv4 through a declarative NetworkManager profile. AdGuard (already live from #820) moves to `hostNetwork` on homelab-0 with a hostPath work directory; its DHCP server is configured from git, static leases included, and switched on only after the owner turns off the modem's DHCPv4.

**Tech Stack:** NixOS flake (`nixos/`, NetworkManager), Helm templates (`apps/templates`, ArgoCD tracks `main`), AdGuard Home v0.107.79 (schema 34), SOPS.

**Spec:** `docs/superpowers/specs/2026-10-31-adguard-dns-design.md` (sections "How DNS flows" and "DHCP", revised 2026-10-31)

## Global Constraints

- Branch `feat/adguard-dhcp`, worktree `~/Projects/thomvandevin/homelab-adguard`. Commits in repo style, no AI attribution lines.
- Node addresses: homelab-0 `enp1s0` 192.168.178.151, homelab-1 `eno2` .152, homelab-2 `eno2` .153; prefix /24; gateway 192.168.178.1; node DNS 9.9.9.9, 1.1.1.1.
- DHCP: interface `enp1s0`, gateway .1, mask 255.255.255.0, range .30-.149, lease 86400 s, option 6 = `192.168.178.160,9.9.9.9`.
- Static leases: exactly the table in the spec's "DHCP" section, plus .21 (`3c:39:e7:2c:7b:12`, HomeWizard P1) and .22 (`34:9f:7b:a0:45:8f`, printer).
- Node network changes are tried with `nixos-rebuild test` (not persistent across reboot) on homelab-2, then homelab-1, then homelab-0, and only made permanent with `switch` after each one passes.
- Stop and ask the owner before: the first node network change, and the DHCP cutover.
- `render` and `check.sh` from the previous plan's workspace are reused (copied into this plan's workspace).

## Review Focus

1. A node whose new profile fails must stay reachable or recover on power cycle: `test`, never `switch`, until verified. Pinned in Task 3.
2. Dynamic leases survive a pod restart, and a static lease changed in git wins over the copy on disk. Pinned in Task 2, step 1 and Task 4, step 3.
3. AdGuard on `hostNetwork` still serves `.160` (LoadBalancer with Local policy to a host-network endpoint) and the LAN UI. Pinned in Task 4, step 2.
4. DHCP stays off until the owner has switched off the modem's server; two DHCP servers never run together. Pinned in Task 5.
5. A device that reconnects after cutover gets `.160,9.9.9.9`, and the TV keeps `.14`. Pinned in Task 5, step 4.

---

### Task 1: Static IPv4 for the nodes

**Files:**
- Modify: `nixos/flake.nix` (per-node `ip` and `interface`, passed through `meta`)
- Modify: `nixos/configuration.nix` (a NetworkManager profile from `meta`)

**Interfaces:**
- Produces: `meta.ip` (string, e.g. `"192.168.178.151"`) and `meta.interface` (e.g. `"enp1s0"`) for every node.

- [ ] **Step 1: Write the failing check** `check-nm.sh` in the workspace: for each of homelab-0/1/2, `nix eval --json ./nixos#nixosConfigurations.<h>.config.networking.networkmanager.ensureProfiles.profiles` must contain a profile with `connection.interface-name` = the node's interface, `ipv4.method` = `manual`, `ipv4.address1` = `<ip>/24,192.168.178.1`, `ipv4.dns` = `9.9.9.9;1.1.1.1;`, and `connection.autoconnect-priority` higher than 0. Run it; expected FAIL (no profile).

- [ ] **Step 2: Implement.** Add `ip`/`interface` to the three node entries in `flake.nix` and inherit them into `meta`. In `configuration.nix`, next to `networking.networkmanager.enable`, define `networking.networkmanager.ensureProfiles.profiles.lan` with the values above, `ipv6.method = "auto"`, and a comment: the nodes cannot depend on DHCP because homelab-0 serves it.

- [ ] **Step 3: Run `check-nm.sh` and `check-nix.sh`.** Expected: both print ok.

- [ ] **Step 4: Commit** `feat(nixos): static IPv4 for the nodes, homelab-0 will serve DHCP`.

### Task 2: AdGuard on the host network with DHCP configured (off)

**Files:**
- Modify: `apps/templates/app-adguard.yaml`
- Modify: `apps/values.yaml` (`adguard.dhcp: false`)
- Modify: `CLAUDE.md` (recovery note)

**Interfaces:**
- Consumes: `.Values.adguard.ip` (exists).
- Produces: `.Values.adguard.dhcp` (bool) flipped in Task 5.

- [ ] **Step 1: Extend `check.sh` and watch it fail.** New assertions on the rendered objects: Deployment `adguard` has `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet`; a hostPath volume `/var/lib/adguard` (type `DirectoryOrCreate`) mounted at `/opt/adguardhome/work`; config `.dhcp.enabled == false`, `.dhcp.interface_name == "enp1s0"`, `.dhcp.dhcpv4.range_start == "192.168.178.30"`, `range_end == "192.168.178.149"`, `lease_duration == 86400`, `options` contains `6 ips 192.168.178.160,9.9.9.9`; a rendered static-lease JSON with 12 entries, all `"static": true`, including `c4:41:1e:b2:45:1c` → `192.168.178.14`. With `--set adguard.dhcp=true`, `.dhcp.enabled == true`.

- [ ] **Step 2: Implement.**
  - Config: a `dhcp:` section from the Global Constraints values, `enabled: {{ .Values.adguard.dhcp }}`, `dhcpv6` left empty.
  - Static leases: a second key `static-leases.json` in the `adguard-config` Secret, `{"version":1,"leases":[...]}` in AdGuard's `leases.json` lease format (`mac`, `ip`, `hostname`, `expires: ""`, `static: true`).
  - Init container switches to the pinned `alpine/k8s` image (has `jq`) and, besides copying the config, writes `/opt/adguardhome/work/data/leases.json` as: dynamic leases from the existing file (if any) whose MAC and IP are not in the static list, plus all static leases from git.
  - Pod: `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`, `strategy: Recreate` (host ports), work volume becomes the hostPath. Container ports unchanged; add 67/UDP `dhcp`.
  - Header comment: one line that the pod is on the host network because DHCP needs the LAN broadcast domain.
  - `CLAUDE.md`: a short "AdGuard serves DHCP" section: homelab-0 hands out addresses; if homelab-0 is down for long, switch the Ziggo modem's DHCPv4 server back on (Advanced settings > DHCP).

- [ ] **Step 3: Run `check.sh alerts`.** Expected: `check ok`, including the `--set adguard.dhcp=true` case.

- [ ] **Step 4: Commit** `feat(adguard): host network, persisted leases and DHCP config from git (disabled)`.

### Task 3: Static node IPs live (asks the owner first)

No files.

- [ ] **Step 1: Ask the owner**, then push the branch.
- [ ] **Step 2: homelab-2**: `ssh homelab@homelab-2 'sudo nixos-rebuild test --flake "github:thomvandevin/homelab/feat/adguard-dhcp?dir=nixos#homelab-2"'`. Expected: completes; `ssh homelab@homelab-2 'nmcli -t -f NAME,DEVICE con show --active; ip -4 addr show eno2'` shows profile `lan` on `eno2` with .153; `kubectl get node homelab-2` Ready. If ssh is lost for more than 2 minutes, stop and ask the owner to power-cycle homelab-2 (the `test` activation is gone after reboot).
- [ ] **Step 3: homelab-1**, same as step 2 with .152.
- [ ] **Step 4: homelab-0**, same with `enp1s0` and .151; also `kubectl get nodes` all Ready and `dig @192.168.178.160 example.com` answers.
- [ ] **Step 5:** Repeat steps 2-4 with `switch` instead of `test` once Task 4's merge is done (switch from `main`). Expected: same results.

### Task 4: Deploy AdGuard on the host network (DHCP still off)

No files.

- [ ] **Step 1: Open PR, merge** (owner already allowed merging), wait for ArgoCD: pod Running on homelab-0 with `hostNetwork`.
- [ ] **Step 2: DNS checks** from the Mac, as in #820: example.com resolves, samba.tv NXDOMAIN, update.biv.sony.tv resolves, `+tcp` works, burst 60/60 against `.160`; `http://192.168.178.160/` answers.
- [ ] **Step 3: Leases file**: `ssh homelab@homelab-0 'sudo jq "[.leases[] | select(.static)] | length" /var/lib/adguard/data/leases.json'` prints `12`. Restart the pod; still `12`, and the AdGuard UI (DHCP page) lists the static leases.

### Task 5: Cutover (owner and Claude together)

No files except `apps/values.yaml`.

- [ ] **Step 1: Ask the owner** to switch the Ziggo modem's DHCPv4 server to Disabled (Advanced settings > DHCP > Status > Disabled > Apply). Existing devices keep their leases.
- [ ] **Step 2:** Set `adguard.dhcp: true` in `apps/values.yaml`, commit `feat(adguard): serve DHCP for the LAN`, PR, merge, wait for the pod to roll.
- [ ] **Step 3:** From the Mac: `sudo ipconfig set en0 DHCP` (or reconnect Wi-Fi), then `ipconfig getpacket en0 | grep -E "server_identifier|domain_name_server|yiaddr|router"`. Expected: server .151 (or .160), DNS `{192.168.178.160, 9.9.9.9}`, router .1, address in .30-.149.
- [ ] **Step 4:** Owner reconnects the TV (or reboots it). AdGuard UI shows the TV at .14 as a static lease; on the TV Netflix, Videoland, Plex, SmartTube, casting and AirPlay work.
- [ ] **Step 5:** Fallback: scale AdGuard to 0; on the Mac `dig example.com` (system resolver) still answers within seconds; scale back to 1.
- [ ] **Step 6:** Home Assistant: `kubectl -n home-assistant logs home-assistant-0 --since=10m | grep -iE "unavailable|timeout" | head` shows no new errors for SLZB, HomeWizard, printer, TV. A pod still resolves samba.tv (cluster unfiltered).
- [ ] **Step 7:** After a day (owner): AdGuard's per-client view shows most devices; record IPv6/second-server bypass in the spec's "IPv6" section.
