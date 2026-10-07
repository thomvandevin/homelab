#!/usr/bin/env bash
set -euo pipefail

config=/etc/workspace
sa=/var/run/secrets/kubernetes.io/serviceaccount
cd "$HOME"

[ -f .bashrc ] || cp /etc/skel/.bashrc /etc/skel/.profile .
mkdir -p .ssh/host .kube .claude Projects
chmod 700 .ssh

[ -f .ssh/host/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f .ssh/host/ssh_host_ed25519_key
[ -f .ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C workspace -f .ssh/id_ed25519
# kubelet's fsGroup pass leaves every file on the volume group-writable, which
# sshd and ssh refuse for private keys
chmod 600 .ssh/host/ssh_host_ed25519_key .ssh/id_ed25519
echo "git public key: $(cat .ssh/id_ed25519.pub)"

install -m 600 "$config/authorized_keys" .ssh/authorized_keys
printf 'StrictHostKeyChecking accept-new\n' > .ssh/config

# sshd starts sessions with a clean environment; this file is the only way
# the tokens and the in-cluster API address reach ssh and VS Code terminals
env | grep -E '^(GH_TOKEN|GITLAB_TOKEN|KUBERNETES_SERVICE_HOST|KUBERNETES_SERVICE_PORT)=' > .ssh/environment || true

if [ ! -f .kube/config ] && [ -f "$sa/token" ]; then
  kubectl config set-cluster in-cluster --server=https://kubernetes.default.svc --certificate-authority="$sa/ca.crt" >/dev/null
  kubectl config set-credentials workspace --token="$(cat "$sa/token")" >/dev/null
  kubectl config set-context in-cluster --cluster=in-cluster --user=workspace >/dev/null
  kubectl config use-context in-cluster >/dev/null
fi

[ -f .claude/settings.json ] || printf '{\n  "includeCoAuthoredBy": false\n}\n' > .claude/settings.json

[ -x .local/bin/claude ] || curl -fsSL https://claude.ai/install.sh | bash || echo "claude install failed, retry by restarting the pod once the network is back"

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global init.defaultBranch main

/usr/sbin/sshd -D -e -f /opt/workspace/sshd_config &
sshd_pid=$!
code-server --auth none --bind-addr 0.0.0.0:8080 --disable-telemetry "$HOME/Projects" 2>&1 | sed 's/^/code-server: /' &

tmux new-session -d -s main -n shell
while IFS='=' read -r name url || [ -n "$name" ]; do
  [ -n "$name" ] && [ -n "$url" ] || continue
  tmux new-window -t main -n "$name" rc-loop "$name" "$url"
done < "$config/repos"

trap 'tmux kill-server 2>/dev/null; kill "$sshd_pid" 2>/dev/null' TERM INT
wait "$sshd_pid"
