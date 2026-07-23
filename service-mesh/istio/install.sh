#!/usr/bin/env bash
# install.sh — install Istio service mesh using Helm charts
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

ISTIO_VERSION="${ISTIO_VERSION:-1.22.2}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"

section "Installing Istio ${ISTIO_VERSION}"

##############################################################################
# Add Istio Helm repo
##############################################################################
helm_repo_add istio https://istio-release.storage.googleapis.com/charts

##############################################################################
# Create namespace
##############################################################################
ensure_namespace "${ISTIO_NAMESPACE}"

##############################################################################
# Install istio/base (CRDs)
##############################################################################
log "Installing Istio base (CRDs)..."
helm upgrade --install istio-base istio/base \
  --version "${ISTIO_VERSION}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --set defaultRevision=default \
  --wait \
  --timeout 3m

ok "Istio base CRDs installed"

##############################################################################
# Install istiod (control plane)
##############################################################################
log "Installing istiod (control plane)..."
helm upgrade --install istiod istio/istiod \
  --version "${ISTIO_VERSION}" \
  --namespace "${ISTIO_NAMESPACE}" \
  --values "${REPO_ROOT}/service-mesh/istio/values.yaml" \
  --set pilot.resources.requests.cpu=100m \
  --set pilot.resources.requests.memory=256Mi \
  --set pilot.resources.limits.cpu=500m \
  --set pilot.resources.limits.memory=512Mi \
  --wait \
  --timeout 5m

ok "istiod installed"
wait_for_rollout "${ISTIO_NAMESPACE}" deployment/istiod 300

##############################################################################
# Install Istio ingress gateway
##############################################################################
log "Installing Istio ingress gateway..."
ensure_namespace istio-ingress

helm upgrade --install istio-ingressgateway istio/gateway \
  --version "${ISTIO_VERSION}" \
  --namespace istio-ingress \
  --set service.type=ClusterIP \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --wait \
  --timeout 3m

ok "Istio ingress gateway installed"

##############################################################################
# Apply Istio manifests
##############################################################################
log "Applying Istio manifests..."
kubectl apply -f "${REPO_ROOT}/service-mesh/istio/manifests/peer-authentication.yaml"
kubectl apply -f "${REPO_ROOT}/service-mesh/istio/manifests/gateway.yaml"

##############################################################################
# Apply ingress gateway resources
##############################################################################
kubectl apply -f "${REPO_ROOT}/ingress/istio/gateway.yaml" 2>/dev/null || true
kubectl apply -f "${REPO_ROOT}/ingress/istio/routes/hello-world-vs.yaml" 2>/dev/null || true

section "Istio Status"
kubectl get pods -n "${ISTIO_NAMESPACE}"
kubectl get svc -n istio-ingress

ok "Istio installation complete"
log "Enable sidecar injection on a namespace with:"
log "  kubectl label namespace <ns> istio-injection=enabled"
