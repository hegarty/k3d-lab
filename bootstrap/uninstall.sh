#!/usr/bin/env bash
# uninstall.sh — destroy the k3d cluster and clean up
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"

section "k3d-lab Uninstall"

log "Cluster to destroy: ${CLUSTER_NAME}"

if ! cluster_exists "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' does not exist — nothing to uninstall"
  exit 0
fi

# Confirm unless --force is passed
if [[ "${1:-}" != "--force" ]]; then
  printf '\033[0;33m[WARN]\033[0m  This will DESTROY cluster "%s" and all its data.\n' "${CLUSTER_NAME}" >&2
  printf '       Press Ctrl+C to cancel, or Enter to continue...' >&2
  read -r
fi

log "Deleting k3d cluster: ${CLUSTER_NAME}..."
k3d cluster delete "${CLUSTER_NAME}"
ok "Cluster '${CLUSTER_NAME}' deleted"

# Clean up kubeconfig context
if kubectl config get-contexts "k3d-${CLUSTER_NAME}" &>/dev/null; then
  kubectl config delete-context "k3d-${CLUSTER_NAME}" 2>/dev/null || true
  ok "kubectl context removed"
fi

if kubectl config get-clusters "k3d-${CLUSTER_NAME}" &>/dev/null; then
  kubectl config delete-cluster "k3d-${CLUSTER_NAME}" 2>/dev/null || true
fi

# Remove any local kubeconfig files
find "${REPO_ROOT}" -maxdepth 1 -name "kubeconfig-*" -delete 2>/dev/null || true

ok "Uninstall complete"
