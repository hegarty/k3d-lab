#!/usr/bin/env bash
# install.sh — install Gateway API CRDs and create the Cilium Gateway
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-1.1.0}"

section "Installing Gateway API v${GATEWAY_API_VERSION}"

##############################################################################
# Install Gateway API standard CRDs
##############################################################################
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/standard-install.yaml"

log "Applying Gateway API CRDs from: ${GATEWAY_API_URL}"
kubectl apply -f "${GATEWAY_API_URL}"

ok "Gateway API CRDs applied"

##############################################################################
# Wait for critical CRDs
##############################################################################
wait_for_crd "gateways.gateway.networking.k8s.io" 60
wait_for_crd "httproutes.gateway.networking.k8s.io" 60
wait_for_crd "grpcroutes.gateway.networking.k8s.io" 60
wait_for_crd "referencegrants.gateway.networking.k8s.io" 60

##############################################################################
# Cilium automatically creates a GatewayClass named "cilium"
# Wait for Cilium to register it (it does this after its own startup)
##############################################################################
log "Waiting for Cilium GatewayClass to appear..."
DEADLINE=$(( $(date +%s) + 120 ))
until kubectl get gatewayclass cilium &>/dev/null; do
  if [[ $(date +%s) -gt "${DEADLINE}" ]]; then
    warn "Cilium GatewayClass not found after 120s — Cilium may need a restart"
    warn "Run: kubectl rollout restart daemonset/cilium -n kube-system"
    break
  fi
  sleep 5
done

if kubectl get gatewayclass cilium &>/dev/null; then
  ok "GatewayClass 'cilium' is available"
  kubectl get gatewayclass cilium
fi

##############################################################################
# Apply the Gateway resource
##############################################################################
log "Applying Gateway..."
kubectl apply -f "${REPO_ROOT}/networking/gateway-api/gateway.yaml"

ok "Gateway applied"

##############################################################################
# Apply example route (hello-world route)
##############################################################################
if kubectl get namespace hello-world &>/dev/null; then
  log "Applying hello-world HTTPRoute..."
  kubectl apply -f "${REPO_ROOT}/networking/gateway-api/routes/hello-world-route.yaml"
  ok "hello-world HTTPRoute applied"
else
  log "hello-world namespace not yet created — route will be applied when workload is deployed"
fi

section "Gateway API Status"
kubectl get gatewayclass
kubectl get gateways -A
echo ""
log "HTTPRoutes:"
kubectl get httproutes -A 2>/dev/null || true
