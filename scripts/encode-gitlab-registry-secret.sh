#!/usr/bin/env bash
# Generate a base64-encoded dockerconfigjson for GitLab Container Registry.
#
# Usage:
#   ./encode-gitlab-registry-secret.sh <username> <access-token>
#
# The access token needs at least `read_registry` scope.
# Create one at: https://gitlab.com/-/user_settings/personal_access_tokens
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <username> <access-token>" >&2
  exit 1
fi

USERNAME="$1"
TOKEN="$2"
REGISTRY="registry.gitlab.com"

AUTH=$(printf '%s:%s' "$USERNAME" "$TOKEN" | base64)

DOCKERCONFIGJSON=$(cat <<EOF
{"auths":{"$REGISTRY":{"username":"$USERNAME","password":"$TOKEN","auth":"$AUTH"}}}
EOF
)

echo -n "$DOCKERCONFIGJSON" | base64
