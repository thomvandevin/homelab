#!/bin/sh
# Reads the cluster every INTERVAL seconds and writes one facts.json for Glance;
# the facts-http container serves it.
set -u
INTERVAL="${INTERVAL:-30}"
WORK=/tmp/facts
OUT=/data
mkdir -p "$WORK" "$OUT"

while true; do
  cd "$WORK" || exit 1
  kubectl get nodes -o json > nodes.json \
    && kubectl get namespaces -o json > namespaces.json \
    && kubectl get pods -A -o json > pods.json \
    && kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes > nodemetrics.json \
    && kubectl get nodes.longhorn.io -n longhorn-system -o json > lhnodes.json \
    && kubectl get volumes.longhorn.io -n longhorn-system -o json > lhvolumes.json \
    && kubectl get replicas.longhorn.io -n longhorn-system -o json > lhreplicas.json \
    && kubectl get deployments,statefulsets,daemonsets -A -o json > workloads.json \
    && kubectl get cronjobs -A -o json > cronjobs.json \
    && kubectl get applications.argoproj.io -n argocd -o json > argo.json \
    && kubectl get ingress -A -o json > ingress.json \
    && kubectl get svc -A -o json > svc.json \
    && kubectl get cm cloudflare-tunnel -n cloudflare-tunnel -o json > tunnel.json \
    && jq -n -f /facts/facts.jq \
         --slurpfile nodes nodes.json --slurpfile namespaces namespaces.json --slurpfile pods pods.json \
         --slurpfile nodemetrics nodemetrics.json --slurpfile lhnodes lhnodes.json \
         --slurpfile lhvolumes lhvolumes.json --slurpfile lhreplicas lhreplicas.json \
         --slurpfile workloads workloads.json --slurpfile cronjobs cronjobs.json \
         --slurpfile argo argo.json --slurpfile ingress ingress.json \
         --slurpfile svc svc.json --slurpfile tunnel tunnel.json \
         > "$OUT/facts.json.tmp" \
    && mv "$OUT/facts.json.tmp" "$OUT/facts.json" \
    || echo "facts: refresh failed at $(date -u +%FT%TZ)" >&2
  sleep "$INTERVAL"
done
