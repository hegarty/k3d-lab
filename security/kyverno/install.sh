#!/usr/bin/env bash
# install.sh — install Kyverno policy engine and default policies
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

KYVERNO_VERSION="${KYVERNO_VERSION:-3.2.6}"
KYVERNO_NAMESPACE="${KYVERNO_NAMESPACE:-kyverno}"

section "Installing Kyverno v${KYVERNO_VERSION}"

##############################################################################
# Add Kyverno Helm repo
##############################################################################
helm_repo_add kyverno https://kyverno.github.io/kyverno/

ensure_namespace "${KYVERNO_NAMESPACE}"

##############################################################################
# Install Kyverno
##############################################################################
log "Installing Kyverno..."
helm upgrade --install kyverno kyverno/kyverno \
  --version "${KYVERNO_VERSION}" \
  --namespace "${KYVERNO_NAMESPACE}" \
  --values "${REPO_ROOT}/security/kyverno/values.yaml" \
  --timeout 5m \
  --wait

ok "Kyverno installed"

##############################################################################
# Wait for admission controller
##############################################################################
wait_for_rollout "${KYVERNO_NAMESPACE}" deployment/kyverno-admission-controller 300

# Wait extra time for webhook to register
log "Waiting for Kyverno webhooks to register..."
sleep 15

##############################################################################
# Apply policies
##############################################################################
log "Applying Kyverno policies..."

POLICY_DIR="${REPO_ROOT}/security/kyverno/policies"

# Apply in order — less restrictive first
kubectl apply -f "${POLICY_DIR}/disallow-latest-tag.yaml"
kubectl apply -f "${POLICY_DIR}/require-non-root.yaml"
kubectl apply -f "${POLICY_DIR}/require-resources.yaml"
kubectl apply -f "${POLICY_DIR}/disallow-privileged.yaml"

ok "Kyverno policies applied"

section "Kyverno Status"
kubectl get pods -n "${KYVERNO_NAMESPACE}"
echo ""
kubectl get clusterpolicy
echo ""
kubectl get policyreport -A 2>/dev/null || true

ok "Kyverno ready"
log "View policy reports: kubectl get policyreport -A"
log "View cluster reports: kubectl get clusterpolicyreport -A"
