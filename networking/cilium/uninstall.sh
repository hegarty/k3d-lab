#!/usr/bin/env bash
# uninstall.sh — remove Cilium from the cluster
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

section "Uninstalling Cilium"

if helm status cilium -n kube-system &>/dev/null; then
  log "Removing Cilium Helm release..."
  helm uninstall cilium -n kube-system --wait --timeout 3m
  ok "Cilium Helm release removed"
else
  warn "Cilium Helm release not found"
fi

# Remove CiliumNetworkPolicy CRDs and resources
log "Removing Cilium CRDs..."
kubectl get crds 2>/dev/null | grep cilium | awk '{print $1}' | \
  xargs -r kubectl delete crd --ignore-not-found || true

ok "Cilium uninstalled"
