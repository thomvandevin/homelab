#!/usr/bin/env bash
# Every workload in apps/templates states where it runs: each Deployment, StatefulSet
# and CronJob has a placement.* helper, and each ArgoCD Application carries a
# thomvandev.in/placement annotation (home, workers or system). Without this a new app
# lands wherever the scheduler likes, homelab-0 included.
set -euo pipefail
cd "${1:-$(dirname "$0")/../apps/templates}"

failed=0
for f in *.yaml; do
  workloads=$(grep -cE '^kind: (Deployment|StatefulSet|CronJob)$' "$f" || true)
  placements=$(grep -c 'include "placement\.' "$f" || true)
  if (( placements < workloads )); then
    echo "$f: $workloads workload(s) but $placements placement include(s)"
    failed=1
  fi
  if grep -qE '^kind: Application$' "$f" && ! grep -qE 'thomvandev\.in/placement: (home|workers|system)$' "$f"; then
    echo "$f: Application without a thomvandev.in/placement annotation"
    failed=1
  fi
done
exit "$failed"
