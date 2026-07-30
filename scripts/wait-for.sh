#!/usr/bin/env bash
# wait-for.sh — readiness helpers
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"

# wait_for_rollout NAMESPACE RESOURCE TIMEOUT_SECONDS
wait_for_rollout() {
  local ns="${1}" resource="${2}" timeout="${3:-300}"
  log "Waiting for rollout: ${resource} in ${ns} (timeout ${timeout}s)..."
  kubectl rollout status "${resource}" -n "${ns}" --timeout="${timeout}s"
  ok "Rollout complete: ${resource}"
}

# wait_for_pods_ready NAMESPACE LABEL_SELECTOR EXPECTED_COUNT TIMEOUT_SECONDS
wait_for_pods_ready() {
  local ns="${1}" selector="${2}" expected="${3:-1}" timeout="${4:-300}"
  local deadline
  deadline=$(( $(date +%s) + timeout ))
  log "Waiting for ${expected} pod(s) ready in ${ns} with selector '${selector}'..."
  while true; do
    local ready
    ready=$(kubectl get pods -n "${ns}" -l "${selector}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | \
      tr ' ' '\n' | grep -c "true" || echo 0)
    if [[ "${ready}" -ge "${expected}" ]]; then
      ok "${ready}/${expected} pod(s) ready in ${ns}"
      return 0
    fi
    if [[ $(date +%s) -gt "${deadline}" ]]; then
      err "Timeout waiting for pods in ${ns} (${ready}/${expected} ready)"
      kubectl get pods -n "${ns}" -l "${selector}" >&2 || true
      return 1
    fi
    sleep 5
  done
}

# wait_for_crd NAME TIMEOUT_SECONDS
wait_for_crd() {
  local name="${1}" timeout="${2:-120}"
  local deadline
  deadline=$(( $(date +%s) + timeout ))
  log "Waiting for CRD: ${name}..."
  until kubectl get crd "${name}" &>/dev/null; do
    if [[ $(date +%s) -gt "${deadline}" ]]; then
      die "Timeout waiting for CRD: ${name}"
    fi
    sleep 3
  done
  ok "CRD ready: ${name}"
}

# wait_for_helm_release NAMESPACE RELEASE TIMEOUT_SECONDS
wait_for_helm_release() {
  local ns="${1}" release="${2}" timeout="${3:-300}"
  local deadline
  deadline=$(( $(date +%s) + timeout ))
  log "Waiting for Helm release: ${release} in ${ns}..."
  until helm status "${release}" -n "${ns}" 2>/dev/null | grep -q "STATUS: deployed"; do
    if [[ $(date +%s) -gt "${deadline}" ]]; then
      err "Helm release ${release} not deployed within ${timeout}s"
      helm status "${release}" -n "${ns}" >&2 || true
      return 1
    fi
    sleep 5
  done
  ok "Helm release '${release}' deployed"
}

# wait_for_url URL TIMEOUT_SECONDS
wait_for_url() {
  local url="${1}" timeout="${2:-60}"
  local deadline
  deadline=$(( $(date +%s) + timeout ))
  log "Waiting for HTTP 200 from: ${url}..."
  until curl -sf --max-time 5 "${url}" &>/dev/null; do
    if [[ $(date +%s) -gt "${deadline}" ]]; then
      err "Timeout waiting for URL: ${url}"
      return 1
    fi
    sleep 3
  done
  ok "URL responding: ${url}"
}
