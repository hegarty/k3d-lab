#!/usr/bin/env bash
# install.sh — install cert-manager and configure issuers
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.15.1}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"

section "Installing cert-manager v${CERT_MANAGER_VERSION}"

##############################################################################
# Add Jetstack Helm repo
##############################################################################
helm_repo_add jetstack https://charts.jetstack.io

ensure_namespace "${CERT_MANAGER_NAMESPACE}"

##############################################################################
# Install cert-manager
##############################################################################
log "Installing cert-manager..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "${CERT_MANAGER_VERSION}" \
  --namespace "${CERT_MANAGER_NAMESPACE}" \
  --values "${REPO_ROOT}/security/cert-manager/values.yaml" \
  --timeout 5m \
  --wait

ok "cert-manager installed"

##############################################################################
# Wait for webhook readiness (critical before applying CRs)
##############################################################################
wait_for_rollout "${CERT_MANAGER_NAMESPACE}" deployment/cert-manager 180
wait_for_rollout "${CERT_MANAGER_NAMESPACE}" deployment/cert-manager-webhook 180

# Wait extra time for webhook to be fully ready
log "Waiting for cert-manager webhook to accept connections..."
sleep 15

##############################################################################
# Apply ClusterIssuers
##############################################################################
log "Applying ClusterIssuers..."
kubectl apply -f "${REPO_ROOT}/security/cert-manager/issuers/selfsigned-issuer.yaml"

# Wait for selfsigned issuer to be ready before creating CA cert
log "Waiting for selfsigned ClusterIssuer..."
DEADLINE=$(( $(date +%s) + 60 ))
until kubectl get clusterissuer selfsigned-issuer -o jsonpath='{.status.conditions[0].type}' 2>/dev/null | grep -q "Ready"; do
  if [[ $(date +%s) -gt "${DEADLINE}" ]]; then
    warn "selfsigned ClusterIssuer not Ready within 60s — continuing anyway"
    break
  fi
  sleep 3
done

kubectl apply -f "${REPO_ROOT}/security/cert-manager/issuers/ca-issuer.yaml"

# Wait for CA certificate to be issued
log "Waiting for CA certificate..."
DEADLINE=$(( $(date +%s) + 120 ))
until kubectl get secret k3d-lab-ca-secret -n cert-manager &>/dev/null; do
  if [[ $(date +%s) -gt "${DEADLINE}" ]]; then
    warn "CA secret not created within 120s"
    break
  fi
  sleep 5
done

# Test certificate
log "Applying test certificate..."
kubectl apply -f "${REPO_ROOT}/security/cert-manager/issuers/test-certificate.yaml"

section "cert-manager Status"
kubectl get pods -n "${CERT_MANAGER_NAMESPACE}"
kubectl get clusterissuer
kubectl get certificate -A 2>/dev/null || true

ok "cert-manager installed and configured"
