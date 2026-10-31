# AdGuard Home DNS Blocking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run AdGuard Home on homelab-0 as the FRITZ!Box's upstream DNS, so every LAN device is filtered while the cluster itself stays unfiltered and the house never loses DNS.

**Architecture:** One AdGuard Home pod on homelab-0, configured entirely from a Helm-rendered Secret that an init container copies into a writable emptyDir on every start. A MetalLB LoadBalancer (192.168.178.160, `externalTrafficPolicy: Local`) serves DNS and the LAN UI; a Tailscale Ingress serves the UI on the tailnet. The nodes' k3s resolv.conf moves from the FRITZ!Box to public resolvers, and the existing Pushover alerts CronJob probes AdGuard.

**Tech Stack:** Helm templates under `apps/templates` (ArgoCD app-of-apps, tracks `main`), SOPS/age secrets, MetalLB L2, Tailscale operator, NixOS (k3s), AdGuard Home.

**Spec:** `docs/superpowers/specs/2026-10-31-adguard-dns-design.md`

## Global Constraints

- Work on branch `feat/adguard-dns`. ArgoCD and `nixos-rebuild --flake github:...` both read `main`, so nothing goes live before the PR is merged (Task 4).
- Commit messages follow the repo style (`feat(adguard): ...`), with no `Co-Authored-By` or other AI attribution lines.
- Images are pinned by tag and digest, like every other template (`image: name:tag@sha256:...`).
- AdGuard LoadBalancer IP: `192.168.178.160` (free; .155 and .156 are in use).
- Blocklists: hagezi Light `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/light.txt`, Perflyst SmartTV `https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt`, and one Dutch list (AdGuard Home's built-in catalogue entry for the Netherlands if it has one, otherwise EasyDutch).
- Allowlist rules: `@@||update.biv.sony.tv^`, `@@||reg.biv.sony.tv^`, `@@||service.biv.sony.tv^`.
- Upstreams: `https://dns.quad9.net/dns-query`, `https://cloudflare-dns.com/dns-query`; bootstrap `9.9.9.9`, `1.1.1.1`.
- Blocking mode `nxdomain`; a blocked name must never answer REFUSED or SERVFAIL.
- Rendering check used throughout, defined once per shell in `apps/` (the on-disk `secrets.yaml.dec` is stale, never use it):
  `render() { SOPS_AGE_KEY_FILE=../key.txt helm template . -f <(SOPS_AGE_KEY_FILE=../key.txt sops -d secrets.yaml); }`

## Review Focus

1. A blocked name answers NXDOMAIN, not REFUSED/SERVFAIL; otherwise the FRITZ!Box retries the alternative server and the block leaks. Pinned in Task 4, step 3.
2. DNS over TCP works through the LoadBalancer (large answers and DNSSEC fall back to TCP). Pinned in Task 4, step 3.
3. A pod restart starts from the git config again, so UI edits never survive and no stale state lingers. Pinned in Task 4, step 5.
4. One slow probe must not page anyone: the alert retries before it fires and sends "resolved" when AdGuard is back. Pinned in Task 2, step 1 and Task 4, step 6.
5. After the node rebuild, pods resolve blocklisted names normally (the cluster is unfiltered), including after CoreDNS restarts. Pinned in Task 3, step 4 and Task 5, step 6.

---

### Task 1: AdGuard Home app

**Files:**
- Create: `apps/templates/app-adguard.yaml`
- Modify: `apps/values.yaml` (add `adguard.ip`)
- Modify: `apps/secrets.yaml` (add `adguard.password_hash`, via `sops set`)

**Interfaces:**
- Produces: `.Values.adguard.ip` (`192.168.178.160`), used by Task 2. Namespace `adguard`, Deployment `adguard`, Services `adguard` (LoadBalancer) and `adguard-ui` (ClusterIP), Ingress `adguard` (tailscale, host `adguard`).

- [ ] **Step 1: Write the render check and watch it fail**

Run in `apps/`:
```bash
render | yq 'select(.metadata.namespace == "adguard" or .metadata.name == "adguard") | .kind + "/" + .metadata.name'
```
Expected now: no output (nothing exists yet). After step 4 it must print exactly: `Namespace/adguard`, `Secret/adguard-config`, `Deployment/adguard`, `Service/adguard`, `Service/adguard-ui`, `Ingress/adguard`.

- [ ] **Step 2: Add the values and the password hash**

`apps/values.yaml`: a top-level `adguard:` block with `ip: 192.168.178.160` and a one-line comment that the FRITZ!Box's preferred DNS server points at it.

Generate a random admin password, then store only its hash:
```bash
PW=$(openssl rand -base64 18); echo "AdGuard admin password: $PW"   # give this to the owner once
HASH=$(htpasswd -nbBC 10 "" "$PW" | tr -d ':\n')
cd apps && SOPS_AGE_KEY_FILE=../key.txt sops set secrets.yaml '["adguard"]["password_hash"]' "\"$HASH\""
```
Expected: `SOPS_AGE_KEY_FILE=../key.txt sops -d secrets.yaml | yq .adguard.password_hash` prints a `$2y$10$...` hash.

- [ ] **Step 3: Look up the config schema and the Dutch list**

For the newest stable `adguard/adguardhome` release: take its digest, read `currentSchemaVersion` from `internal/home/upgrade.go` (or the equivalent in that tag), and check the built-in filter catalogue (`client/src/helpers/filters/filters.json` or the current equivalent) for a Dutch/Netherlands entry and its URL. If there is none, use the EasyDutch list URL from easydutch.nl. Note all three values for step 4.

- [ ] **Step 4: Write `apps/templates/app-adguard.yaml`**

Follow `app-matter-server.yaml` for layout and comments. Contents:
- Namespace `adguard` with annotation `glance/icon: di:adguard-home`.
- Secret `adguard-config`, key `AdGuardHome.yaml`, rendered with `schema_version` from step 3, `http.address: 0.0.0.0:3000`, one user `admin` with `.Values.adguard.password_hash`, `dns.bind_hosts: [0.0.0.0]`, `dns.port: 53`, the upstreams and bootstrap from Global Constraints, `filtering.blocking_mode: nxdomain`, the three `filters` (enabled), and `user_rules` with the three allowlist rules. Put the lists and allowlist first in the file with a comment saying this is where false blocks get fixed.
- Deployment `adguard`: `replicas: 1`, `{{- include "placement.homelab0" . | nindent 6 }}`, an init container (busybox, pinned) that copies the Secret's `AdGuardHome.yaml` into an emptyDir mounted at `/opt/adguardhome/conf` on every start, a second emptyDir at `/opt/adguardhome/work`, container ports 53/UDP, 53/TCP, 3000/TCP, a TCP readiness probe on 53, small requests (for example 50m CPU, 128Mi memory) and a memory limit. A pod annotation with the sha256 of the rendered config so a config change rolls the pod (as `app-glance.yaml` does with `checksum/config`).
- Service `adguard`: `type: LoadBalancer`, annotation `metallb.io/loadBalancerIPs: {{ .Values.adguard.ip }}`, `externalTrafficPolicy: Local`, ports in this order: `http` 80→3000/TCP (first, because Glance builds its LAN link from the first port), `dns-udp` 53/UDP, `dns-tcp` 53/TCP.
- Service `adguard-ui` (ClusterIP, 80→3000) and Ingress `adguard` with `ingressClassName: tailscale` and `tls.hosts: [adguard]`, shaped like the `code` Ingress in `app-workspace.yaml`.

- [ ] **Step 5: Run the render check**

Run the step 1 command. Expected: the six objects listed in step 1. Also `render | yq 'select(.kind == "Service" and .metadata.name == "adguard") | .spec.ports[0].port'` prints `80`.

- [ ] **Step 6: Commit**

```bash
git add apps/templates/app-adguard.yaml apps/values.yaml apps/secrets.yaml
git commit -m "feat(adguard): AdGuard Home on homelab-0 with lists and allowlist from git"
```

### Task 2: AdGuard probe in the alerts watcher

**Files:**
- Modify: `apps/templates/alerts.yaml` (the `watch.sh` script and the header comment)

**Interfaces:**
- Consumes: `.Values.adguard.ip` from Task 1.
- Produces: a problem key `dns adguard down` in the `alerts-state` ConfigMap.

- [ ] **Step 1: Add the probe**

In `watch.sh`, after `nodes=...`: a `dns` variable that is `dns adguard down` when three attempts of `nslookup -timeout=5 quad9.net {{ .Values.adguard.ip }}` all fail, empty otherwise. Add it to `current`. In the alert `case`, `dns)` notifies `"AdGuard down"` with a message saying the house is on the FRITZ!Box fallback and unfiltered, priority 0. Extend the "ready again" loop so a previous `dns ` key that is no longer current sends `"AdGuard back"`. Add a line about AdGuard to the header comment.

- [ ] **Step 2: Run the render check**

Run: `render | yq 'select(.metadata.name == "alerts-watch" and .kind == "ConfigMap") | .data["watch.sh"]' | grep -c 192.168.178.160`
Expected: at least `1`. Then pipe the same script through `sh -n` (syntax only). Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add apps/templates/alerts.yaml
git commit -m "feat(alerts): page when AdGuard stops answering"
```

### Task 3: Keep the cluster unfiltered

**Files:**
- Modify: `nixos/configuration.nix:125-133`

**Interfaces:**
- Produces: nodes whose k3s resolv.conf no longer contains `192.168.178.1`. Applied live in Task 5.

- [ ] **Step 1: Confirm nothing in the cluster needs the router for names**

`grep -rnE 'fritz\.box|192\.168\.178\.1([^0-9]|$)' apps/templates apps/files apps/values.yaml nixos` found only the resolv.conf line during planning. Re-run it; expected: only `nixos/configuration.nix`. If anything else shows up, add a forward for that zone to `192.168.178.1` in `apps/templates/coredns-custom.yaml` next to the tailnet block.

- [ ] **Step 2: Change the resolv.conf**

Replace `nameserver 192.168.178.1` with `nameserver 9.9.9.9`, keep `nameserver 1.1.1.1`. Extend the comment above it with one line: the router is not used because it forwards to AdGuard, and cluster workloads must stay unfiltered.

- [ ] **Step 3: Check the NixOS config still evaluates**

Run: `nix eval ./nixos#nixosConfigurations.homelab-0.config.environment.etc."k3s/resolv.conf".text` (if `nix` is available locally; otherwise this check moves to Task 5, step 2, where the rebuild itself evaluates it).
Expected: the text with `9.9.9.9` and `1.1.1.1`, no `192.168.178.1`.

- [ ] **Step 4: Commit**

```bash
git add nixos/configuration.nix
git commit -m "feat(nixos): resolve cluster DNS via public resolvers, not the router"
```

### Task 4: Merge, deploy and verify AdGuard directly

No files. Router untouched, so nothing in the house changes yet.

- [ ] **Step 1: Open the PR and merge**

Push `feat/adguard-dns` and open a PR with the spec and plan linked. Merge only after the owner approves.

- [ ] **Step 2: Wait for ArgoCD**

Run: `kubectl -n adguard get pods -o wide; kubectl -n adguard get svc adguard`
Expected: one `Running` pod on `homelab-0`; `EXTERNAL-IP` `192.168.178.160`.

- [ ] **Step 3: Answer checks (from the Mac on the LAN)**

```bash
dig +short @192.168.178.160 example.com              # an address
dig @192.168.178.160 samba.tv | grep status          # status: NXDOMAIN (Perflyst/hagezi), never REFUSED/SERVFAIL
dig +short @192.168.178.160 update.biv.sony.tv       # an address (allowlisted)
dig +tcp +short @192.168.178.160 example.com         # an address over TCP
```
If `samba.tv` is not on the active lists, use any domain present in hagezi Light.

- [ ] **Step 4: UI and Glance**

Open `http://192.168.178.160/` and `https://adguard.snowy-gorgon.ts.net`, log in with the generated password, check the three filters show rule counts. On `http://homelab/` the AdGuard tile shows its icon and working links.

- [ ] **Step 5: Config comes from git only**

In the UI, add a throwaway custom rule. Run `kubectl -n adguard rollout restart deploy/adguard`, wait for Ready, reload the UI. Expected: the rule is gone, the three allowlist rules are there.

- [ ] **Step 6: Alert path**

`kubectl -n adguard scale deploy/adguard --replicas=0`, trigger the watcher once (`kubectl -n alerts create job --from=cronjob/alerts-watch adguard-test`), expect an "AdGuard down" Pushover message. Scale back to 1, wait for Ready, run the job again (new name), expect "AdGuard back". Delete both test jobs.

### Task 5: Rebuild nodes, switch the router, verify the house

No repo files, except the spec if the IPv6 gap shows up.

- [ ] **Step 1: Rebuild every node**

On homelab-1, homelab-2, then homelab-0: `sudo nixos-rebuild switch --flake "github:thomvandevin/homelab?dir=nixos#<host>"` (exact form in `nixos/README.md`). Expected on each: `cat /etc/k3s/resolv.conf` shows `9.9.9.9` and no `192.168.178.1`.

- [ ] **Step 2: Restart CoreDNS so it reads the new file**

Run: `kubectl -n kube-system rollout restart deploy/coredns && kubectl -n kube-system rollout status deploy/coredns`
Expected: rolled out.

- [ ] **Step 3: Owner changes the FRITZ!Box**

Internet > Account Information > DNS Server: "Use other DNSv4 servers", preferred `192.168.178.160`, alternative `9.9.9.9`. DNS over TLS for these servers off. This is done by the owner in the FRITZ!Box UI.

- [ ] **Step 4: House checks (spec "Verification" 1-4)**

From the Mac (which uses the FRITZ!Box):
```bash
dig @192.168.178.1 samba.tv | grep status                       # NXDOMAIN
dig @<FRITZ!Box IPv6 address from `scutil --dns`> samba.tv | grep status   # NXDOMAIN, or record the gap
dig +short @192.168.178.1 example.com update.biv.sony.tv          # both resolve
```
Scale AdGuard to 0: `dig @192.168.178.1 example.com` still resolves within a few seconds. Scale back to 1. With AdGuard up, browse for a minute and check the AdGuard query log shows the traffic (from the FRITZ!Box); if most lookups are missing while AdGuard is healthy, stop and tell the owner. If IPv6 lookups bypass AdGuard and the router cannot be changed, add the finding to the spec's "IPv6" section and commit it.

- [ ] **Step 5: TV checks (owner)**

Netflix, Videoland, Plex, SmartTube, casting and AirPlay work on the TV.

- [ ] **Step 6: Cluster stays unfiltered**

Run: `kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.37 -- nslookup samba.tv`
Expected: an address, not NXDOMAIN.
