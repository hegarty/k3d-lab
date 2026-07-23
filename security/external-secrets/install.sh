#!/usr/bin/env bash
# install.sh — install External Secrets Operator and configure fake store for local dev
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

EXTERNAL_SECRETS_VERSION="${EXTERNAL_SECRETS_VERSION:-0.10.0}"
EXTERNAL_SECRETS_NAMESPACE="${EXTERNAL_SECRETS_NAMESPACE:-external-secrets}"

section "Installing External Secrets Operator v${EXTERNAL_SECRETS_VERSION}"

##############################################################################
# Add External Secrets Helm repo
##############################################################################
helm_repo_add external-secrets https://charts.external-secrets.io

ensure_namespace "${EXTERNAL_SECRETS_NAMESPACE}"

##############################################################################
# Install External Secrets Operator
##############################################################################
log "Installing External Secrets Operator..."
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "${EXTERNAL_SECRETS_VERSION}" \
  --namespace "${EXTERNAL_SECRETS_NAMESPACE}" \
  --values "${REPO_ROOT}/security/external-secrets/values.yaml" \
  --timeout 5m \
  --wait

ok "External Secrets Operator installed"

##############################################################################
# Wait for webhook
##############################################################################
wait_for_rollout "${EXTERNAL_SECRETS_NAMESPACE}" deployment/external-secrets 180
wait_for_rollout "${EXTERNAL_SECRETS_NAMESPACE}" deployment/external-secrets-webhook 180

sleep 10

##############################################################################
# Apply fake store (for local dev — no real secret backend needed)
##############################################################################
log "Applying fake ClusterSecretStore for local development..."
kubectl apply -f "${REPO_ROOT}/security/external-secrets/secret-stores/fake-store.yaml"
kubectl apply -f "${REPO_ROOT}/security/external-secrets/secret-stores/example-secret.yaml"

section "External Secrets Status"
kubectl get pods -n "${EXTERNAL_SECRETS_NAMESPACE}"
kubectl get clustersecretstore 2>/dev/null || true
kubectl get externalsecret -A 2>/dev/null || true

ok "External Secrets Operator ready"
log "ClusterSecretStore 'fake-store' is configured for local testing"
log "Add real stores in: security/external-secrets/secret-stores/"
