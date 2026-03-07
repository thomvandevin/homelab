#!/usr/bin/env bash
# Encrypt secrets.yaml.dec to secrets.yaml using SOPS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIXOS_DIR="$SCRIPT_DIR/../nixos"

pushd "$NIXOS_DIR" > /dev/null
sops --encrypt --input-type yaml --output-type yaml secrets.yaml.dec > secrets.yaml
popd > /dev/null

echo "Encrypted secrets.yaml.dec -> secrets.yaml"
