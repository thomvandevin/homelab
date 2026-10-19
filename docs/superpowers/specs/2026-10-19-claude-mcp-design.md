# Claude connectors for the homelab

## Goal

Ask Claude from any device (claude.ai, phone app) about the homelab and have it
answer from live data: "what's the address of the SLZB coordinator", "is Sonarr
healthy", "why is rustfs crash looping". Later, act: sync an ArgoCD app,
restart a deployment, trigger a Sonarr search. Work (bol.com) is out of scope
and gets its own project and connectors.

Code changes from the phone are already covered by the workspace pod (one
Remote Control session per repo, GitLab repos included) and are not part of
this design.

## Approach

Two small MCP servers, one per place where the credentials already live, put
behind one Cloudflare MCP server portal so claude.ai sees a single connector.
Home Assistant's built-in MCP server is the third upstream.

```
claude.ai connector
  -> mcp.thomvandev.in (Cloudflare MCP portal, Access + managed OAuth)
       -> homelab-mcp  (k8s, ArgoCD)        cluster, inventory
       -> homelab-media-mcp (homelab-media, compose) *arr, SABnzbd, Plex
       -> Home Assistant /api/mcp (own OAuth)  entities exposed to Assist
```

Rejected: a single gateway. It would hold the cluster service account, every
*arr API key and the HA token in one pod, so one bug exposes all of it, and the
media API keys (which live in the apps' `config.xml` on the media host) would
have to be copied into this repo's SOPS file and kept in sync. The portal
removes the gateway's one real advantage, a single connector URL.

Rejected: a separate "network" server. Network questions are lookups and fold
into the inventory tool.

## Auth

Layered so that no single leaked value reaches the cluster.

1. **Cloudflare Access** (existing Zero Trust org, one-time PIN login) in
   front of every MCP hostname, Allow policy on the owner's email only,
   managed OAuth turned on. The claude.ai connector gets short-lived OAuth
   tokens; there is no static bearer token anywhere.
2. **JWT check in each server.** Requests must carry a valid
   `Cf-Access-Jwt-Assertion` (signature from the team JWKS, `aud` of that
   server's Access app). A request that reaches the pod any other way
   (in-cluster, a mistaken tunnel route) is rejected.
3. **Scoped identities inside.** `homelab-mcp` runs as its own service
   account with a read-only ClusterRole in the shape of `glance-facts`: no
   Secrets, no `pods/exec`. It never uses the workspace's cluster-admin
   account. `homelab-media-mcp` only gets the *arr / SABnzbd / Plex keys, read from
   the same `.env` the compose stack already uses.
4. **Writes are opt-in.** Write tools only register when `MCP_WRITE=true`.
   They bind a second ClusterRole (`patch` on `deployments` for the restart
   annotation, `patch` on `argoproj.io/applications` for a sync operation) and
   sit behind their own Access app so their policy can be stricter (shorter
   session, re-login).

Cloudflare Access apps, the portal and the tunnel hostname are created through
the Cloudflare API and recorded in this spec's plan; the tunnel route itself
lives in `cloudflare-tunnel.yaml` like every other hostname.

## homelab-mcp (phase 1, read-only)

| Tool | Source |
|---|---|
| `cluster_problems()` | `facts.json` (nodes, apps, workloads, cron jobs, Longhorn, ArgoCD) plus pods that are not running or were terminated in the last 24 hours |
| `inventory(query)` | node addresses from the API, app links, LoadBalancer IPs and Ingresses from `facts.json` |
| `cluster_facts(section)` | one section of `facts.json` |
| `pod_status(ns)` | phase, restarts, waiting reason, last termination, requests and limits |
| `pod_logs(ns, pod)` | `pods/log`, at most 500 lines; logs can contain secrets, so this tool is the first to drop if that worries us |

Reuse: `facts.json` is produced by the Glance sidecar (`facts.jq`) and served
by its `facts-http` container; a ClusterIP Service `glance/glance-facts`
exposes it, so the MCP does not re-derive the same data. The MCP's own
ClusterRole is only `get`/`list` on nodes, pods and `pods/log`.

Home Assistant device addresses (SLZB, HomeWizard, Sonos and the like) are
not in phase 1: HA's REST API does not expose config entry hosts, so they
arrive with the Home Assistant MCP in phase 3, or with a small HA template
sensor if that proves insufficient.

The router (Ziggo SmartWifi, Liberty Global RDK firmware) has no usable API
for DHCP leases, so LAN devices that Home Assistant does not know about are
out of scope. A later option is an ARP/nmap sweep from a node.

Image: private GitLab project `thomvandevin-projects/homelab-mcp`, built by
the homelab GitLab runner, deployed by an ArgoCD-managed template
`apps/templates/app-homelab-mcp.yaml`. Language: Go with the official MCP Go
SDK (stateless streamable HTTP) and `go-oidc` for the Access JWT; one static
binary on a distroless image.

## homelab-media-mcp (phase 2, read-only)

Runs as one more service in `homelab-media`'s `docker-compose.yml`, deployed
by that repo's existing deploy script. Tools: `queue()` (Sonarr, Radarr,
Lidarr, SABnzbd, Transmission), `health()` (`/api/v3/health` per *arr),
`calendar(days)`, `search_library(title)`. The tunnel reaches it by LAN IP,
the same way it reaches Navidrome.

## Home Assistant (phase 3)

Enable the `mcp_server` integration in the UI (config entries live in
`.storage`, not in the home-assistant repo) and pick the entities exposed to
Assist; that exposure list is exactly what MCP can see and control. HA does
its own OAuth, so it joins the portal as an OAuth upstream, or is added as a
separate connector at `https://homeassistant.thomvandev.in/api/mcp`.

## Writes (phase 4)

`argocd_sync(app)`, `restart(ns, deployment)`, `sonarr_search(series)`,
behind `MCP_WRITE=true` and the stricter Access app. Every write is logged
with the Access identity.

## Status (2026-10-19)

Phases 1, 2 and 4 are live; writes ship switched off. Phase 3 needs the
integration added in the HA UI. The MCP portal is not built: Home Assistant
does its own OAuth and stays a separate connector anyway, so the portal would
only merge two connectors into one, at the price of either a static Access
service token for the upstreams or a dashboard login per upstream. Revisit
when there are more servers. Operating notes: `docs/claude-connectors.md`.

## Docs (phase 5)

`docs/claude-connectors.md`: how to add the portal URL as a custom connector
in claude.ai, how to rotate the Access app, how to turn writes on and off.

## Out of scope

Work environment, Talos cluster, GitHub mirrors, metrics (Prometheus is
disabled; `cluster_status` reads the API directly).
