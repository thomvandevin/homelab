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
