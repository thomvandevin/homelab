# Claude connectors

Live homelab data in claude.ai (web, desktop, phone). Design and reasoning:
`docs/superpowers/specs/2026-10-19-claude-mcp-design.md`.

| Connector URL | Server | Runs on | Tools |
|---|---|---|---|
| `https://homelab-mcp.thomvandev.in/mcp` | `homelab-mcp` (GitLab `thomvandevin-projects/homelab-mcp`) | cluster, `apps/templates/app-homelab-mcp.yaml` | `cluster_problems`, `inventory`, `cluster_facts`, `pod_status`, `pod_logs`; writes: `restart_deployment`, `argocd_sync` |
| `https://media-mcp.thomvandev.in/mcp` | `media-mcp` (homelab-media `docker/media-mcp`) | homelab-media, Docker Compose | `media_health`, `media_queue`, `media_calendar`, `library_search`, `plex_now_playing`; writes: `sonarr_search`, `radarr_search` |
| `https://homeassistant.thomvandev.in/api/mcp` | Home Assistant's built-in `mcp_server` | cluster, Home Assistant | entities exposed to Assist |

## Adding a connector

claude.ai > Settings > Connectors > Add custom connector, paste the URL, leave
the OAuth fields empty. For the two homelab servers a Cloudflare page asks for
an email and sends a one-time PIN (only `endbossing@gmail.com` gets one; any
other address silently gets nothing). For Home Assistant, log in with the HA
account. Connectors added on the web show up in the phone and desktop apps.

## How it is protected

- **Cloudflare Access** apps `homelab-mcp` and `media-mcp` (Zero Trust >
  Access > Applications): Allow policy on the owner's email, one-time PIN
  login, managed OAuth with dynamic client registration for the claude.ai and
  claude.com callbacks and localhost (Claude Code). Access tokens live 15
  minutes, the grant two weeks; policies are re-checked on every refresh.
- **The servers** reject any request without a valid Access JWT for their own
  app (`ACCESS_AUD`), so reaching the pod or the host port directly does not
  help.
- **homelab-mcp** runs as a service account that can only `get`/`list` nodes,
  pods and `pods/log`. No Secrets, no exec. **media-mcp** only holds the *arr,
  SABnzbd and Plex keys it reads from the media host's `.env`.

To cut access at once: Zero Trust > My Team > Users > Revoke sessions, or
delete the Access application.

## Turning writes on and off

Off by default; tools that write are not even listed while off.

- **homelab-mcp**: `homelabMcp.write: true` in `apps/values.yaml`. This also
  renders the RBAC the writes need (`patch` on Deployments, `get`/`patch` on
  ArgoCD Applications) and removes it again when set back to `false`.
- **media-mcp**: change `MEDIA_MCP_WRITE=${MEDIA_MCP_WRITE:-false}` to `true`
  in homelab-media's `docker/docker-compose.yml`, then
  `docker compose up -d --no-deps media-mcp` on the host.

Every write is logged with the tool and its arguments.

## Home Assistant

Settings > Devices & services > Add integration > Model Context Protocol
Server, choose "Assist" so Claude can control what it can see. Then Settings >
Voice assistants > Expose: only exposed entities are visible to Claude. The
integration is UI-only, so it lives in `.storage` on the HA volume, not in the
home-assistant repo.

## Deploying changes

- homelab-mcp: push to `main` in its GitLab project; CI tests, builds and
  restarts the Deployment.
- media-mcp: on the media host, `docker compose build media-mcp && docker
  compose up -d --no-deps media-mcp` (`--no-deps` keeps Sonarr and Radarr
  running). The image build runs `go vet` and the tests.
