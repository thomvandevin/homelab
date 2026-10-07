# Always-on Claude Code workspace: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `workspace` StatefulSet in the k3s cluster that keeps one `claude remote-control` server per repo alive, reachable over the tailnet by SSH and code-server, so Claude Code sessions are driven from claude.ai/code and the desktop app without a MacBook.

**Architecture:** One image (`workspace/`) carrying tools, sshd, code-server, an entrypoint and an `rc-loop` supervisor; built by GitHub Actions to `ghcr.io/thomvandevin/workspace`. One Helm template (`apps/templates/app-workspace.yaml`) with a StatefulSet on a Longhorn home volume, a cluster-admin ServiceAccount, a Tailscale LoadBalancer Service for SSH and a Tailscale Ingress for code-server. Claude Code itself is installed onto the volume at first boot and self-updates.

**Tech Stack:** Debian bookworm, OpenSSH, tmux, code-server, Claude Code native installer, Helm 4 templates rendered by ArgoCD, Tailscale operator, Longhorn, GitHub Actions, Renovate.

**Spec:** `docs/superpowers/specs/2026-10-07-workspace-design.md`

## Global Constraints

- Subscription login only: the image, manifest and entrypoint never set `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_GROWTHBOOK`.
- The Remote Control server runs inside `~/Projects/<repo>`, never in `$HOME`.
- Container runs as uid 1000 (`dev`), home `/home/dev`; nothing needs root at runtime.
- No AI attribution anywhere: commit messages in this plan carry none, and git identity in the pod is the owner's.
- Public repo: no tokens, emails, IPs or tailnet names in committed files; secrets go through `apps/secrets.yaml` (sops).
- Follow existing template conventions: Namespace with `glance/icon`, `placement.workersOnly`, Tailscale Service/Ingress shapes from `app-glance.yaml` and `app-pokemon-ai.yaml`.
- Validation is `helm template` + `kubectl --dry-run=client` and a local `docker run` smoke test; there is no test framework in this repo.

## Review Focus

1. Entrypoint re-run on an already-populated volume must not regenerate keys or clobber `~/.claude`: Task 1 step 8 restarts the container against the same volume and asserts the public key is unchanged.
2. A repos line with an empty name or a trailing blank line must not open a broken tmux window: Task 1 step 7 feeds a trailing newline and checks the window list.
3. `claude remote-control` exiting (not logged in, offline) must be restarted, not leave a dead window: Task 1 step 7 captures the pane and expects the restart message.
4. sshd under a non-root user on a fsGroup-owned home must still accept the key: `StrictModes no` in `sshd_config`, verified by the SSH login in Task 1 step 7.
5. The Secret must render even before the owner fills the tokens: Task 3 renders with the real `secrets.yaml.dec` after the keys are added, and the entrypoint tolerates empty `GH_TOKEN`/`GITLAB_TOKEN`.

---

### Task 1: Workspace image

**Files:**
- Create: `workspace/Dockerfile`
- Create: `workspace/sshd_config`
- Create: `workspace/entrypoint.sh`
- Create: `workspace/rc-loop`
- Create: `workspace/.dockerignore`

**Interfaces:**
- Produces: image expecting a read-only mount at `/etc/workspace` with files `authorized_keys` (one public key per line) and `repos` (`NAME=URL` per line); a writable volume at `/home/dev`; env `GIT_USER_NAME`, `GIT_USER_EMAIL`, optional `RC_SPAWN` (`same-dir` or `worktree`), optional `GH_TOKEN`, `GITLAB_TOKEN`. Listens on 2222 (ssh) and 8080 (code-server). Task 3's manifest relies on exactly these paths, ports and names.

- [ ] **Step 1: Dockerfile**

```dockerfile
FROM debian:bookworm-slim

ARG TARGETARCH
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=1.37.1
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=4.3.0
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION=3.13.3
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION=1.3.2
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.102.0
# renovate: datasource=gitlab-releases depName=gitlab-org/cli
ARG GLAB_VERSION=1.121.0
# renovate: datasource=github-releases depName=coder/code-server
ARG CODE_SERVER_VERSION=4.140.0
ARG NODE_MAJOR=24

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gnupg jq less openssh-client openssh-server \
      procps ripgrep tmux unzip vim-tiny xz-utils \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "linux-${TARGETARCH}/helm" \
    && curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${TARGETARCH}" -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops \
    && curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 age/age age/age-keygen \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.deb" -o /tmp/gh.deb \
    && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${TARGETARCH}.deb" -o /tmp/glab.deb \
    && dpkg -i /tmp/gh.deb /tmp/glab.deb \
    && rm /tmp/*.deb \
    && curl -fsSL https://code-server.dev/install.sh | sh -s -- --method standalone --prefix /usr/local --version "${CODE_SERVER_VERSION}"

# sshd refuses to start without its privilege separation directory, even as
# a non-root user that cannot use it
RUN mkdir -p /run/sshd \
    && useradd --create-home --uid 1000 --shell /bin/bash dev

COPY sshd_config /opt/workspace/sshd_config
COPY entrypoint.sh rc-loop /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/rc-loop

USER dev
WORKDIR /home/dev
ENV PATH="/home/dev/.local/bin:${PATH}"
EXPOSE 2222 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 2: sshd_config**

```
Port 2222
HostKey /home/dev/.ssh/host/ssh_host_ed25519_key
PidFile /home/dev/.ssh/host/sshd.pid
AuthorizedKeysFile /home/dev/.ssh/authorized_keys
AllowUsers dev
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
# The home volume is owned through fsGroup, which leaves it group-writable;
# sshd's default mode check would reject the key for that alone
StrictModes no
# Non-interactive ssh commands (VS Code's probes, scripts) skip .profile,
# so the Claude binary on the volume has to be on PATH here
SetEnv PATH=/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
```

- [ ] **Step 3: entrypoint.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

config=/etc/workspace
cd "$HOME"

[ -f .bashrc ] || cp /etc/skel/.bashrc /etc/skel/.profile .
mkdir -p .ssh/host Projects .config
chmod 700 .ssh

[ -f .ssh/host/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f .ssh/host/ssh_host_ed25519_key
[ -f .ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C workspace -f .ssh/id_ed25519
echo "git public key: $(cat .ssh/id_ed25519.pub)"

install -m 600 "$config/authorized_keys" .ssh/authorized_keys
[ -f .ssh/known_hosts ] || ssh-keyscan -t ed25519 github.com gitlab.com > .ssh/known_hosts 2>/dev/null

[ -x .local/bin/claude ] || curl -fsSL https://claude.ai/install.sh | bash

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global init.defaultBranch main

/usr/sbin/sshd -D -e -f /opt/workspace/sshd_config &
sshd_pid=$!
code-server --auth none --bind-addr 0.0.0.0:8080 --disable-telemetry "$HOME/Projects" >/dev/null 2>&1 &

tmux new-session -d -s main -n shell
while IFS='=' read -r name url; do
  [ -n "$name" ] && [ -n "$url" ] || continue
  tmux new-window -t main -n "$name" "rc-loop '$name' '$url'"
done < "$config/repos"

wait "$sshd_pid"
```

- [ ] **Step 4: rc-loop**

```bash
#!/usr/bin/env bash
name=$1
url=$2
dir="$HOME/Projects/$name"

while true; do
  if [ ! -d "$dir/.git" ]; then
    if ! git clone "$url" "$dir"; then
      echo "clone of $name failed, retrying in 60s"
      sleep 60
      continue
    fi
  fi
  (cd "$dir" && claude remote-control --name "$name" --spawn "${RC_SPAWN:-same-dir}")
  echo "remote-control for $name exited, restarting in 10s"
  sleep 10
done
```

- [ ] **Step 5: .dockerignore and syntax check**

`workspace/.dockerignore`:

```
README.md
```

Run: `bash -n workspace/entrypoint.sh && bash -n workspace/rc-loop && echo syntax-ok`
Expected: `syntax-ok`

- [ ] **Step 6: Build locally**

Run: `docker build -t workspace:dev workspace`
Expected: build succeeds. If a download URL 404s, check the release asset name on that project's release page and fix the URL pattern in the Dockerfile; do not loosen the version pin.

- [ ] **Step 7: Smoke test the container**

```bash
S=/private/tmp/claude-501/-Users-thomvandevin-Projects-thomvandevin-homelab/7c14a740-fb61-4b5f-bea4-c5194be87bd1/scratchpad/ws
mkdir -p "$S/home" "$S/cfg"
ssh-keygen -q -t ed25519 -N '' -f "$S/testkey"
cp "$S/testkey.pub" "$S/cfg/authorized_keys"
printf 'homelab=https://github.com/thomvandevin/homelab.git\n\n' > "$S/cfg/repos"
docker run -d --name ws -u 1000:1000 \
  -e GIT_USER_NAME=test -e GIT_USER_EMAIL=test@example.com \
  -v "$S/home:/home/dev" -v "$S/cfg:/etc/workspace:ro" \
  -p 2222:2222 -p 8080:8080 workspace:dev
sleep 60
docker logs ws | grep 'git public key: ssh-ed25519'
ssh -p 2222 -i "$S/testkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null dev@localhost \
  'kubectl version --client --output=yaml | head -2 && helm version --short && sops --version && gh --version | head -1 && glab --version && claude --version'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/
docker exec ws tmux list-windows -t main
docker exec ws ls /home/dev/Projects/homelab/.git >/dev/null && echo cloned
docker exec ws tmux capture-pane -pt main:homelab | tail -5
```

Expected: the public key line is printed; the SSH command prints each tool's version including `claude`; `200` (or `302`) from code-server; `tmux list-windows` shows exactly `shell` and `homelab` (the blank line opened no window); `cloned`; the captured pane shows a Claude login/eligibility error followed by `remote-control for homelab exited, restarting in 10s` (not logged in, so the loop is exercised).

- [ ] **Step 8: Idempotence across restart**

```bash
key1=$(cat "$S/home/.ssh/id_ed25519.pub")
docker rm -f ws
docker run -d --name ws -u 1000:1000 \
  -e GIT_USER_NAME=test -e GIT_USER_EMAIL=test@example.com \
  -v "$S/home:/home/dev" -v "$S/cfg:/etc/workspace:ro" \
  -p 2222:2222 -p 8080:8080 workspace:dev
sleep 20
[ "$key1" = "$(cat "$S/home/.ssh/id_ed25519.pub")" ] && echo key-kept
docker logs ws | grep -c 'Installing' || echo no-reinstall
docker rm -f ws
```

Expected: `key-kept`; no Claude installer output on the second boot (`no-reinstall` or count `0`).

- [ ] **Step 9: Commit**

```bash
git add workspace
git commit -m "feat(workspace): image with sshd, code-server and a remote-control loop per repo"
```

---

### Task 2: Image build workflow and Renovate coverage

**Files:**
- Create: `.github/workflows/build-workspace.yaml`
- Modify: `.github/renovate.json` (append to `customManagers`)

**Interfaces:**
- Produces: `ghcr.io/thomvandevin/workspace:latest` and `:sha-<commit>` on every push to `main` touching `workspace/**`; PRs build without pushing.

- [ ] **Step 1: Workflow**

```yaml
name: workspace image
run-name: workspace image
on:
  workflow_dispatch:
  pull_request:
    paths:
      - "workspace/**"
      - ".github/workflows/build-workspace.yaml"
  push:
    branches:
      - main
    paths:
      - "workspace/**"
      - ".github/workflows/build-workspace.yaml"

permissions:
  contents: read
  packages: write

jobs:
  build:
    name: Build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        if: github.event_name != 'pull_request'
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: workspace
          push: ${{ github.event_name != 'pull_request' }}
          tags: |
            ghcr.io/thomvandevin/workspace:latest
            ghcr.io/thomvandevin/workspace:sha-${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Renovate custom manager for the Dockerfile ARGs**

Append this object to the `customManagers` array in `.github/renovate.json`, after the existing argocd entry:

```json
{
  "description": "Tool versions baked into the workspace image",
  "customType": "regex",
  "datasourceTemplate": "{{{datasource}}}",
  "depNameTemplate": "{{{depName}}}",
  "extractVersionTemplate": "^v?(?<version>.+)$",
  "managerFilePatterns": [
    "/^workspace/Dockerfile$/"
  ],
  "matchStrings": [
    "# renovate: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)\\s*\\nARG \\S+=(?<currentValue>\\S+)"
  ]
}
```

- [ ] **Step 3: Validate both files**

Run: `python3 -c 'import json,yaml;json.load(open(".github/renovate.json"));yaml.safe_load(open(".github/workflows/build-workspace.yaml"));print("ok")'`
Expected: `ok`. If `yaml` is missing locally, use `ruby -ryaml -e 'YAML.load_file(".github/workflows/build-workspace.yaml"); puts "ok"'`.

Run: `grep -c '# renovate: datasource' workspace/Dockerfile`
Expected: `7`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-workspace.yaml .github/renovate.json
git commit -m "ci(workspace): build the image to ghcr and let renovate bump its tools"
```

---

### Task 3: Kubernetes manifest and values

**Files:**
- Create: `apps/templates/app-workspace.yaml`
- Modify: `apps/values.yaml` (append `workspace:` block)
- Modify: `apps/secrets.yaml.dec` and re-encrypt `apps/secrets.yaml`

**Interfaces:**
- Consumes: image contract from Task 1 (`/etc/workspace/{authorized_keys,repos}`, `/home/dev`, ports 2222/8080, env names).
- Produces: tailnet hosts `workspace` (SSH) and `code` (HTTPS); namespace `workspace`; pod `workspace-0`.

- [ ] **Step 1: values.yaml**

Append to `apps/values.yaml`:

```yaml

workspace:
  gitUserName: Thom van de Vin
  # same-dir shares one checkout per repo; worktree gives every session
  # started from claude.ai its own git worktree
  spawn: same-dir
  authorizedKeys:
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL0dyepv7Mynvj4EqLWfM0DtAz20ZI8+AfU/qhHiAsXP thomvandevin@thomvandevin-macbook.local
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBR653yMYwe9MQkwYTR0QUQu1cFAcgzxKIGqd6iIlz1o tvandevin@LMAC-N6CFJ7CWGC
  repos:
    homelab: git@github.com:thomvandevin/homelab.git
```

(The two keys are the ones already public in `nixos/configuration.nix`.)

- [ ] **Step 2: secrets**

Add to `apps/secrets.yaml.dec` (ask the owner for the real values; empty strings are acceptable to start, the pod runs without them):

```yaml
workspace:
  gitUserEmail: ""
  githubToken: ""
  gitlabToken: ""
```

Re-encrypt:

```bash
cd apps && SOPS_AGE_KEY_FILE=../key.txt sops --encrypt --input-type yaml --output-type yaml secrets.yaml.dec > secrets.yaml && cd ..
```

Run: `SOPS_AGE_KEY_FILE=key.txt sops --decrypt --extract '["workspace"]' apps/secrets.yaml`
Expected: the three keys print.

- [ ] **Step 3: Template**

`apps/templates/app-workspace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    glance/icon: mdi:console
  name: workspace
  labels:
    name: workspace
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workspace
  namespace: workspace
---
# The workspace replaces the laptop's kubeconfig, so it gets the same reach
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: workspace-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: workspace
    namespace: workspace
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: workspace-config
  namespace: workspace
data:
  authorized_keys: |
    {{- range .Values.workspace.authorizedKeys }}
    {{ . }}
    {{- end }}
  repos: |
    {{- range $name, $url := .Values.workspace.repos }}
    {{ $name }}={{ $url }}
    {{- end }}
---
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: workspace-secret
  namespace: workspace
data:
  GIT_USER_EMAIL: {{ .Values.workspace.gitUserEmail | b64enc | quote }}
  GH_TOKEN: {{ .Values.workspace.githubToken | b64enc | quote }}
  GITLAB_TOKEN: {{ .Values.workspace.gitlabToken | b64enc | quote }}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: workspace
  namespace: workspace
spec:
  serviceName: workspace
  replicas: 1
  selector:
    matchLabels:
      app: workspace
  template:
    metadata:
      labels:
        app: workspace
    spec:
      {{- include "placement.workersOnly" . | nindent 6 }}
      serviceAccountName: workspace
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: workspace
          image: ghcr.io/thomvandevin/workspace:latest
          imagePullPolicy: Always
          ports:
            - name: ssh
              containerPort: 2222
            - name: http
              containerPort: 8080
          env:
            - name: GIT_USER_NAME
              value: {{ .Values.workspace.gitUserName | quote }}
            - name: RC_SPAWN
              value: {{ .Values.workspace.spawn | quote }}
          envFrom:
            - secretRef:
                name: workspace-secret
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              memory: 8Gi
          livenessProbe:
            tcpSocket:
              port: ssh
            initialDelaySeconds: 60
            periodSeconds: 30
          volumeMounts:
            - name: home
              mountPath: /home/dev
            - name: config
              mountPath: /etc/workspace
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: workspace-config
  volumeClaimTemplates:
    - metadata:
        name: home
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 50Gi
---
# A tailnet device named "workspace": `ssh dev@workspace` and VS Code Remote-SSH
apiVersion: v1
kind: Service
metadata:
  name: workspace
  namespace: workspace
  annotations:
    tailscale.com/hostname: workspace
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app: workspace
  ports:
    - name: ssh
      port: 22
      targetPort: ssh
---
apiVersion: v1
kind: Service
metadata:
  name: code
  namespace: workspace
spec:
  type: ClusterIP
  selector:
    app: workspace
  ports:
    - name: http
      port: 80
      targetPort: http
---
# -- Tailscale Ingress (internal only) ----------------------------------------
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: code
  namespace: workspace
spec:
  ingressClassName: tailscale
  rules:
    - http:
        paths:
          - backend:
              service:
                name: code
                port:
                  number: 80
            path: "/"
            pathType: Prefix
  tls:
    - hosts:
        - code
```

- [ ] **Step 4: Render and dry-run**

Run:

```bash
helm template apps -f apps/secrets.yaml.dec --show-only templates/app-workspace.yaml > /private/tmp/claude-501/-Users-thomvandevin-Projects-thomvandevin-homelab/7c14a740-fb61-4b5f-bea4-c5194be87bd1/scratchpad/workspace.yaml
grep -A3 '  repos: |' /private/tmp/claude-501/-Users-thomvandevin-Projects-thomvandevin-homelab/7c14a740-fb61-4b5f-bea4-c5194be87bd1/scratchpad/workspace.yaml
kubectl apply --dry-run=client -f /private/tmp/claude-501/-Users-thomvandevin-Projects-thomvandevin-homelab/7c14a740-fb61-4b5f-bea4-c5194be87bd1/scratchpad/workspace.yaml
```

Expected: the ConfigMap shows `homelab=git@github.com:thomvandevin/homelab.git` on its own line under `repos: |`; dry-run lists namespace, serviceaccount, clusterrolebinding, configmap, secret, statefulset, two services and the ingress as `created (dry run)` with no errors. Also run `helm template apps -f apps/secrets.yaml.dec > /dev/null && echo chart-ok` to make sure the whole chart still renders.

- [ ] **Step 5: Commit**

```bash
git add apps/templates/app-workspace.yaml apps/values.yaml apps/secrets.yaml
git commit -m "feat(workspace): statefulset with tailnet ssh and code-server"
```

---

### Task 4: Bootstrap documentation and pull request

**Files:**
- Create: `workspace/README.md`

- [ ] **Step 1: README**

`workspace/README.md`:

````markdown
# Workspace

Always-on Claude Code workspace: one `claude remote-control` server per repo
in `apps/values.yaml` (`workspace.repos`), driven from claude.ai/code or the
Claude desktop app. Reachable on the tailnet as `workspace` (SSH, port 22)
and `code` (code-server over HTTPS).

## One-time bootstrap

1. Register the pod's git key with GitLab and GitHub:
   ```bash
   kubectl -n workspace logs workspace-0 | grep 'git public key'
   ```
2. Sign in to claude.ai (prints a URL; open it anywhere, paste the code back):
   ```bash
   kubectl -n workspace exec -it workspace-0 -- claude auth login
   ```
3. Answer the one-time prompts in each repo window (`Enable Remote Control?`,
   `Trust <directory>?`), then detach with `Ctrl-b d`:
   ```bash
   kubectl -n workspace exec -it workspace-0 -- tmux attach
   ```
   Switch windows with `Ctrl-b n`. Each window then shows its session URL.
4. Copy the sops age key so sessions can edit `apps/secrets.yaml`:
   ```bash
   ssh dev@workspace 'mkdir -p ~/.config/sops/age'
   scp key.txt dev@workspace:~/.config/sops/age/keys.txt
   ```

Everything above lives on the `home` volume; pod restarts need none of it.

## Day to day

- Sessions: claude.ai/code, one per repo, named after the repo.
- Editor: VS Code Remote-SSH to `dev@workspace`, or `https://code.<tailnet>.ts.net`.
- Add a repo: add it under `workspace.repos`, ArgoCD restarts the pod, the
  loop clones it and a new window appears. Answer the trust prompt once.
- Attach to the servers: `kubectl -n workspace exec -it workspace-0 -- tmux attach`.
- Claude Code updates itself in `~/.local`; tool versions in the image are
  bumped by Renovate.

## Failure modes

| Event | Result |
|---|---|
| Pod or node restart | servers restart; sessions younger than 4 h resume, older ones are archived |
| Anthropic unreachable > 10 min | the server exits and the loop restarts it every 10 s |
| A session crashes | it is re-served on the next message from the app |
| Login expired | the window shows the error; repeat bootstrap step 2 |
````

- [ ] **Step 2: Commit and open the PR**

```bash
git add workspace/README.md
git commit -m "docs(workspace): bootstrap and operations"
git push -u origin feat/workspace
gh pr create --title "feat: always-on Claude Code workspace" --body "$(cat <<'EOF'
- `workspace/`: image with sshd, code-server, tmux and a `remote-control` loop per repo; Claude Code installs onto the home volume and self-updates
- `app-workspace.yaml`: StatefulSet on Longhorn, cluster-admin ServiceAccount, Tailscale Service `workspace` (ssh) and Ingress `code`
- build workflow to ghcr, Renovate manager for the image's tool versions
- values: `workspace.repos`, `workspace.authorizedKeys`; secrets: git email, gh/glab tokens
EOF
)"
```

The `pull_request` trigger builds the image without pushing; wait for the `workspace image` check to pass before merging.

Run: `gh pr checks --watch`
Expected: `workspace image` passes.

---

### Task 5: Deploy, bootstrap and verify

No files. Performed with the owner, after the PR is merged.

- [ ] **Step 1: Make the package public**

On github.com, Packages, `workspace`, Package settings, Change visibility to Public. Confirm anonymously: `docker manifest inspect ghcr.io/thomvandevin/workspace:latest >/dev/null && echo public`.

- [ ] **Step 2: Wait for ArgoCD**

Run: `kubectl -n workspace get sts,pod,svc,ingress,pvc`
Expected: `workspace-0` Running, PVC Bound, Service `workspace` with a tailnet hostname in `EXTERNAL-IP`, Ingress `code` with an address.

- [ ] **Step 3: Bootstrap**

Follow `workspace/README.md` steps 1 to 4 with the owner.

- [ ] **Step 4: Verify**

- `ssh dev@workspace kubectl get nodes` lists the three nodes.
- `https://code.<tailnet>.ts.net` opens code-server on `~/Projects`.
- claude.ai/code lists a `homelab` session; sending it "run kubectl get nodes" from the phone succeeds.
- `kubectl -n workspace delete pod workspace-0`; within two minutes the session is back online at claude.ai/code without any manual step.
- Add the first GitLab repo to `workspace.repos` and confirm a second window and session appear after sync.

- [ ] **Step 5: Record the outcome**

If any verification step failed, fix it on a follow-up branch; do not mark the plan complete until step 4 passes end to end.
