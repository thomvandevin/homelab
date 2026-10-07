# Always-on Claude Code workspace in the cluster

## Goal

Close the MacBook. A workspace pod in the cluster holds the project checkouts
and runs Claude Code in Remote Control server mode, so sessions are driven from
claude.ai/code and the Claude desktop app, with VS Code (Remote-SSH or a
browser) for hand edits. After a node reboot or pod restart the sessions come
back on their own; the only manual work is a one-time bootstrap.

Constraints: claude.ai subscription only, no API keys. Repos on gitlab.com
(primary) and GitHub, committed under the owner's own identity with no AI
attribution. Full cluster-admin from inside the workspace, accepted as the
same blast radius as the MacBook today. Declarative and ArgoCD-managed like
every other app here.

## Approach

One StatefulSet, one Longhorn volume as the home directory, one container
from our own tools image. It runs sshd, code-server (no auth of its own, only
the tailnet reaches it) and a tmux server with one window per repo; each
window loops `claude remote-control --name <repo>` inside `~/Projects/<repo>`.
code-server lives in the same image rather than as a sidecar so its
integrated terminal has the same tools, PATH and Claude binary as the
sessions.

Reachable on the tailnet as `workspace` (SSH, Tailscale LoadBalancer Service)
and `code` (HTTPS, Tailscale Ingress), the same two patterns glance and the
registry use.

Rejected:

- Claude Code on the web: Anthropic-hosted sandboxes cannot reach the tailnet
  (no kubectl, no sops key) and cannot push to GitLab.
- Coder: a control plane plus Terraform templates to get one long-lived
  workspace. Worth revisiting only if several isolated workspaces per repo
  become a need; this image would drop into a Coder template unchanged.
- OpenClaw / Hermes style agent runtimes: a second agent loop next to Claude
  Code, with their own credential surface, for no gain here.
- CI bots (`@claude` on issues and PRs): not wanted.
- Running the server on a NixOS node directly: works, but puts the workspace
  on the host with host-level access and outside ArgoCD.

## Remote Control facts the design relies on

From https://code.claude.com/docs/en/remote-control:

- `claude remote-control` is a long-lived server per directory; sessions are
  created from claude.ai/code or the app, up to `--capacity` (default 32).
- Restarting the server in the same directory brings back the sessions it was
  serving for about four hours. Crashed sessions are re-served on the next
  message without a server restart.
- The server exits by itself after roughly 10 minutes without reaching
  Anthropic, so it must be supervised.
- Requires a full claude.ai login (`claude auth login`); `setup-token` and
  `CLAUDE_CODE_OAUTH_TOKEN` cannot establish Remote Control sessions.
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_GROWTHBOOK`,
  `ANTHROPIC_API_KEY` and a custom `ANTHROPIC_BASE_URL` must all be unset.
- Two one-time prompts (`Enable Remote Control?` and `Trust <directory>?`)
  need a terminal and are persisted in `~/.claude.json`. Trust is never saved
  for `$HOME` itself, so the server always runs inside a project directory.

## Components

### Image (`workspace/Dockerfile`, built by GitHub Actions)

Debian base, non-root user `dev` (uid 1000, home `/home/dev`). Tools: git,
openssh-server, tmux, curl, jq, ripgrep, node (LTS), kubectl, helm, sops, age,
gh, glab, code-server. Tool versions are `ARG`s with `# renovate:` markers so
Renovate bumps them like the argocd init-container tools. No Claude Code
binary: the entrypoint installs it with the native
installer into `~/.local` on first boot and it self-updates there, so Claude
releases need no image rebuild.

Built on `ubuntu-latest` by `.github/workflows/build-workspace.yaml` on
pushes touching `workspace/**`, pushed to `ghcr.io/thomvandevin/workspace`
tagged `latest` and by commit SHA. The package is set public once by hand so
the cluster pulls without a secret. Renovate keeps the base image digest
current as it does for other images.

### Entrypoint (`workspace/entrypoint.sh`)

1. Generate SSH host keys into `~/.ssh/host/` and a client key
   `~/.ssh/id_ed25519` if missing; print the public key to the log so it can
   be added to GitLab and GitHub.
2. Write `~/.ssh/authorized_keys` from the mounted ConfigMap.
3. Install Claude Code if `~/.local/bin/claude` is missing.
4. Configure git identity from env (`GIT_USER_NAME`, `GIT_USER_EMAIL`).
5. Start sshd (port 2222, user `dev`, key-only) and code-server (port 8080,
   `--auth none`, opened on `~/Projects`).
6. Start a detached tmux server; for every `NAME=URL` line in the mounted
   repos file open a window named `NAME` running `rc-loop NAME URL`.
7. `wait` on the sshd process so PID 1 stays up; sshd stopping ends the
   container and Kubernetes restarts it.

`rc-loop`: forever { clone `URL` into `~/Projects/NAME` if the directory is
missing (fails harmlessly until the SSH key is registered); `cd` into it and
run `claude remote-control --name NAME --spawn $RC_SPAWN`; sleep 10 }. The
loop runs in a tmux pane, so the one-time prompts can be answered by
attaching, and the server's status view (session URL, QR code) is visible the
same way.

### Kubernetes objects (`apps/templates/app-workspace.yaml`)

- Namespace `workspace` (`glance/icon: mdi:console`).
- ServiceAccount `workspace` + ClusterRoleBinding to `cluster-admin`.
  kubectl inside the pod uses the mounted token; no kubeconfig is copied.
- ConfigMap `workspace-config`: `authorized_keys`, `repos` (one `NAME=URL`
  per line, rendered from values).
- Secret `workspace-secret`: `GH_TOKEN`, `GITLAB_TOKEN` from sops values, for
  `gh` and `glab` (PRs and MRs; clones and pushes go over SSH).
- StatefulSet `workspace`, 1 replica, `placement.workersOnly`, runs as uid
  1000 with `fsGroup: 1000`, `volumeClaimTemplates` for `home` (Longhorn,
  50Gi) mounted at `/home/dev`. One container from the image above; env from
  the Secret plus `GIT_USER_NAME`, `GIT_USER_EMAIL`, `RC_SPAWN` from values;
  requests 500m / 2Gi, limit 8Gi memory; ports 2222 and 8080.
- Service `workspace` (`type: LoadBalancer`, `loadBalancerClass: tailscale`,
  `tailscale.com/hostname: workspace`) exposing port 22 to 2222.
- Service `code` (ClusterIP, 8080) and Ingress `code`
  (`ingressClassName: tailscale`, host `code`) for HTTPS on the tailnet.
The root `apps` Application renders every file in `apps/templates`, so no
per-app ArgoCD Application is needed.

### Values

```yaml
workspace:
  gitUserName: Thom van de Vin
  spawn: same-dir          # or worktree for isolated parallel sessions
  authorizedKeys:
    - ssh-ed25519 ...
  repos:
    homelab: git@github.com:thomvandevin/homelab.git
```

`secrets.yaml` gains `workspace.gitUserEmail`, `workspace.githubToken` and
`workspace.gitlabToken`; `values.yaml` holds the rest.

### One-time bootstrap (documented in `workspace/README.md`)

1. `kubectl -n workspace logs workspace-0 -c workspace`: copy the printed
   public key into GitLab and GitHub.
2. `kubectl -n workspace exec -it workspace-0 -c workspace -- claude auth
   login`: open the URL on any device, paste the code back.
3. `kubectl ... exec -it ... -- tmux attach`: in each window answer
   `Enable Remote Control?` and `Trust <directory>?` with `y`. The windows
   then show the session URLs.
4. `scp` the sops age key to `~/.config/sops/age/keys.txt` over the tailnet.

From here on, nothing is manual: a pod restart re-runs the entrypoint
against the same volume and the servers re-register.

## Behaviour on failure

| Event | Result |
|---|---|
| Pod or node restart | entrypoint re-runs; servers come back; sessions younger than 4 h resume, older ones are archived and new ones are created on demand |
| Anthropic unreachable > 10 min | server exits, `rc-loop` restarts it every 10 s until it sticks |
| A session crashes | re-served on the next message from the app |
| Repo clone fails (key not yet registered) | loop retries; the window shows the git error |
| Login expires | Claude prints the error in the window; redo bootstrap step 2 |

## Security notes

- The pod holds cluster-admin, git push rights to every listed repo, PR/MR
  tokens and (after bootstrap) the sops key: treat it exactly like the
  MacBook. Permission mode stays at the default so destructive tool calls
  still prompt in the app.
- Nothing listens outside the tailnet. sshd is key-only; code-server has no
  auth of its own and relies on the Tailscale ingress.
- The image contains no secrets; everything sensitive lives on the volume or
  in the sops-managed Secret.

## Verification

- `helm template apps` renders; ArgoCD shows `workspace` Synced/Healthy.
- `ssh dev@workspace` and `https://code.<tailnet>.ts.net` work from a tailnet
  device; VS Code Remote-SSH opens `~/Projects/homelab`.
- Each repo appears as a session at claude.ai/code; a message from the phone
  runs `kubectl get nodes` successfully.
- `kubectl -n workspace delete pod workspace-0`: within two minutes the
  sessions are back online without any manual step.
