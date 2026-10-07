#!/usr/bin/env bash
# Builds the image and boots it three times against the same home volume:
# offline first (sshd must come up without the Claude installer or any host
# key scan), then online (tools, code-server, tmux windows, clone, restart
# loop), then after a kubelet-style fsGroup walk over the volume (keys keep
# working, nothing is regenerated or clobbered).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
scratch=${1:-$(mktemp -d)}
image=workspace:dev
name=workspace-smoke
volume=workspace-smoke-home
config=workspace-smoke-config
sa=workspace-smoke-sa
ssh_port=${SSH_PORT:-2222}
http_port=${HTTP_PORT:-8080}

fail() {
  echo "FAIL: $*" >&2
  docker logs "$name" 2>&1 | tail -20 >&2
  exit 1
}

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap 'cleanup; docker volume rm "$volume" "$config" "$sa" >/dev/null 2>&1 || true' EXIT
cleanup
docker volume rm "$volume" "$config" "$sa" >/dev/null 2>&1 || true

# Docker Desktop only bind-mounts shared paths, so the config goes in through
# a volume filled over stdin
mkdir -p "$scratch"
[ -f "$scratch/testkey" ] || ssh-keygen -q -t ed25519 -N '' -f "$scratch/testkey"
docker run --rm -i -v "$config:/etc/workspace" debian:bookworm-slim \
  sh -c 'cat > /etc/workspace/authorized_keys' < "$scratch/testkey.pub"
printf 'homelab=https://github.com/thomvandevin/homelab.git\n\n' | docker run --rm -i -v "$config:/etc/workspace" debian:bookworm-slim \
  sh -c 'cat > /etc/workspace/repos'
# stands in for the projected ServiceAccount token Kubernetes mounts
docker run --rm -v "$sa:/sa" debian:bookworm-slim sh -c 'echo fake-token > /sa/token; echo fake-ca > /sa/ca.crt'

run() {
  docker run -d --name "$name" -u 1000:1000 "$@" \
    -e GIT_USER_NAME=test -e GIT_USER_EMAIL=test@example.com \
    -e GH_TOKEN=gh-test-token -e GITLAB_TOKEN=gl-test-token \
    -v "$volume:/home/dev" -v "$config:/etc/workspace:ro" -v "$sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
    -p "$ssh_port:2222" -p "$http_port:8080" "$image" >/dev/null
}

wait_for_ssh() {
  for _ in $(seq 1 "$1"); do
    ssh -q -p "$ssh_port" -i "$scratch/testkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=2 dev@localhost true 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

remote() {
  ssh -q -p "$ssh_port" -i "$scratch/testkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null dev@localhost "$@"
}

docker build -q -t "$image" "$here" >/dev/null || fail "image build"

echo "== offline boot"
# --network none also drops port publishing, so this boot is checked from inside
run --network none
for _ in $(seq 1 30); do docker exec "$name" pgrep -x sshd >/dev/null 2>&1 && break; sleep 2; done
docker exec "$name" pgrep -x sshd >/dev/null || fail "sshd not running without network"
docker exec "$name" test ! -e /home/dev/.local/bin/claude || fail "claude present after an offline boot"
docker exec "$name" grep -q "StrictHostKeyChecking accept-new" /home/dev/.ssh/config || fail "ssh client config missing accept-new"
started=$(date +%s)
docker stop -t 30 "$name" >/dev/null
[ $(( $(date +%s) - started )) -lt 10 ] || fail "container ignored SIGTERM"
cleanup

echo "== online boot"
run
wait_for_ssh 60 || fail "sshd not reachable"
grep -q 'git public key: ssh-ed25519' <<< "$(docker logs "$name" 2>&1)" || fail "public key not printed"

tools=$(remote 'echo "kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)";
  echo "helm $(helm version --short)"; echo "sops $(sops --version --disable-version-check)";
  echo "gh $(gh --version | head -1)"; echo "glab $(glab --version)"; echo "claude $(claude --version)"')
echo "$tools"
for t in kubectl helm sops gh glab claude; do
  echo "$tools" | grep -qE "^$t .*[0-9]+\.[0-9]+\.[0-9]+" || fail "$t missing over ssh"
done

[ "$(remote 'kubectl config view -o jsonpath={.clusters[0].cluster.server}')" = "https://kubernetes.default.svc" ] || fail "kubeconfig not generated"
[ "$(remote 'echo "$GH_TOKEN $GITLAB_TOKEN"')" = "gh-test-token gl-test-token" ] || fail "tokens not exported to ssh sessions"
[ "$(remote 'jq .includeCoAuthoredBy .claude/settings.json')" = "false" ] || fail "attribution not disabled in claude settings"

for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$http_port/" || true)
  [ "$code" = 200 ] || [ "$code" = 302 ] && break
  sleep 2
done
[ "$code" = 200 ] || [ "$code" = 302 ] || fail "code-server answered $code"

windows=$(docker exec "$name" tmux list-windows -t main -F '#W' | sort | tr '\n' ' ')
[ "$windows" = "homelab shell " ] || fail "tmux windows: $windows"

for _ in $(seq 1 60); do
  docker exec "$name" test -d /home/dev/Projects/homelab/.git && break
  sleep 2
done
docker exec "$name" test -d /home/dev/Projects/homelab/.git || fail "homelab not cloned"

for _ in $(seq 1 30); do
  pane=$(docker exec "$name" tmux capture-pane -pt main:homelab)
  echo "$pane" | grep -q 'remote-control for homelab exited, restarting in 10s' && break
  sleep 2
done
echo "$pane" | tail -5
echo "$pane" | grep -q 'remote-control for homelab exited, restarting in 10s' || fail "rc-loop did not restart the server"

key1=$(docker exec "$name" cat /home/dev/.ssh/id_ed25519.pub)
docker exec "$name" sh -c 'echo "{\"custom\":true,\"includeCoAuthoredBy\":false}" > /home/dev/.claude/settings.json'
cleanup

echo "== boot after fsGroup walk"
# kubelet applies mode|0660 to every file on a fsGroup volume at mount time
docker run --rm -v "$volume:/home/dev" debian:bookworm-slim chmod -R g+rw /home/dev
run
wait_for_ssh 60 || fail "sshd not reachable after fsGroup walk"
[ "$key1" = "$(docker exec "$name" cat /home/dev/.ssh/id_ed25519.pub)" ] || fail "git key regenerated"
[ "$(docker exec "$name" stat -c %a /home/dev/.ssh/id_ed25519)" = 600 ] || fail "git key left group-readable"
grep -qi 'installing' <<< "$(docker logs "$name" 2>&1)" && fail "claude reinstalled after restart"
[ "$(remote 'jq .custom .claude/settings.json')" = "true" ] || fail "claude settings clobbered"

echo "PASS"
