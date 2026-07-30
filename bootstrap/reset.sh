#!/usr/bin/env bash
# reset.sh — destroy and recreate the cluster
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"
CLUSTER_PROFILE="${CLUSTER_PROFILE:-single-node}"

section "k3d-lab Reset"

log "This will destroy and recreate cluster '${CLUSTER_NAME}' (profile: ${CLUSTER_PROFILE})"

if [[ "${1:-}" != "--force" ]]; then
  printf '\033[0;33m[WARN]\033[0m  All cluster data will be lost.\n' >&2
  printf '       Press Ctrl+C to cancel, or Enter to continue...' >&2
  read -r
fi

# Destroy
log "Destroying cluster..."
bash "${REPO_ROOT}/bootstrap/uninstall.sh" --force

# Pause briefly so Docker can clean up networks
sleep 3

# Recreate
log "Recreating cluster..."
CLUSTER_PROFILE="${CLUSTER_PROFILE}" CLUSTER_NAME="${CLUSTER_NAME}" \
  bash "${REPO_ROOT}/bootstrap/install.sh"

ok "Reset complete — cluster '${CLUSTER_NAME}' is fresh"
