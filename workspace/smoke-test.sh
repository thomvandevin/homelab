#!/usr/bin/env bash
# Builds the image and boots it twice against the same home volume:
# first boot proves ssh, code-server, the tmux windows, the clone and the
# restart loop; second boot proves nothing on the volume is regenerated.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
scratch=${1:-$(mktemp -d)}
image=workspace:dev
name=workspace-smoke
volume=workspace-smoke-home
config=workspace-smoke-config
ssh_port=${SSH_PORT:-2222}
http_port=${HTTP_PORT:-8080}

fail() {
  echo "FAIL: $*" >&2
  docker logs "$name" 2>&1 | tail -20 >&2
  exit 1
}

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap 'cleanup; docker volume rm "$volume" "$config" >/dev/null 2>&1 || true' EXIT
cleanup
docker volume rm "$volume" "$config" >/dev/null 2>&1 || true

# Docker Desktop only bind-mounts shared paths, so the config goes in through
# a volume filled over stdin
mkdir -p "$scratch"
[ -f "$scratch/testkey" ] || ssh-keygen -q -t ed25519 -N '' -f "$scratch/testkey"
docker run --rm -i -v "$config:/etc/workspace" debian:bookworm-slim \
  sh -c 'cat > /etc/workspace/authorized_keys' < "$scratch/testkey.pub"
printf 'homelab=https://github.com/thomvandevin/homelab.git\n\n' | docker run --rm -i -v "$config:/etc/workspace" debian:bookworm-slim \
  sh -c 'cat > /etc/workspace/repos'

run() {
  docker run -d --name "$name" -u 1000:1000 \
    -e GIT_USER_NAME=test -e GIT_USER_EMAIL=test@example.com \
    -v "$volume:/home/dev" -v "$config:/etc/workspace:ro" \
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

echo "== first boot"
run
wait_for_ssh 60 || fail "sshd not reachable"
docker logs "$name" | grep -q 'git public key: ssh-ed25519' || fail "public key not printed"

tools=$(remote 'echo "kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)";
  echo "helm $(helm version --short)"; echo "sops $(sops --version --disable-version-check)";
  echo "gh $(gh --version | head -1)"; echo "glab $(glab --version)"; echo "claude $(claude --version)"')
echo "$tools"
for t in kubectl helm sops gh glab claude; do
  echo "$tools" | grep -qE "^$t .*[0-9]+\.[0-9]+\.[0-9]+" || fail "$t missing over ssh"
done

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

echo "== second boot"
key1=$(docker exec "$name" cat /home/dev/.ssh/id_ed25519.pub)
cleanup
run
wait_for_ssh 60 || fail "sshd not reachable after restart"
[ "$key1" = "$(docker exec "$name" cat /home/dev/.ssh/id_ed25519.pub)" ] || fail "git key regenerated"
docker logs "$name" | grep -qi 'installing' && fail "claude reinstalled on second boot"

echo "PASS"
