#!/usr/bin/env bash
# install.sh — install MetalLB for LoadBalancer support in k3d
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

METALLB_CHART_VERSION="${METALLB_CHART_VERSION:-0.14.5}"
CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"

section "Installing MetalLB ${METALLB_CHART_VERSION}"

##############################################################################
# Detect Docker network CIDR for the k3d cluster
##############################################################################
log "Detecting Docker network CIDR for k3d-${CLUSTER_NAME}..."

DOCKER_NETWORK="k3d-${CLUSTER_NAME}"
NETWORK_CIDR=$(docker network inspect "${DOCKER_NETWORK}" \
  --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || echo "")

if [[ -z "${NETWORK_CIDR}" ]]; then
  warn "Could not detect Docker network CIDR. Using default 172.18.0.0/16"
  NETWORK_CIDR="172.18.0.0/16"
fi

log "Docker network: ${DOCKER_NETWORK}, CIDR: ${NETWORK_CIDR}"

# Derive the pool range from the network (last /24 within the /16, range 200-250)
NETWORK_BASE=$(echo "${NETWORK_CIDR}" | cut -d/ -f1 | cut -d. -f1-2)
POOL_START="${NETWORK_BASE}.100.200"
POOL_END="${NETWORK_BASE}.100.250"
log "MetalLB pool: ${POOL_START} - ${POOL_END}"

##############################################################################
# Helm install
##############################################################################
helm_repo_add metallb https://metallb.github.io/metallb

ensure_namespace metallb-system

helm upgrade --install metallb metallb/metallb \
  --version "${METALLB_CHART_VERSION}" \
  --namespace metallb-system \
  --values "${REPO_ROOT}/networking/metallb/values.yaml" \
  --wait \
  --timeout 3m

ok "MetalLB Helm release deployed"

##############################################################################
# Wait for MetalLB webhook and speaker
##############################################################################
wait_for_rollout metallb-system deployment/metallb-controller 120
wait_for_rollout metallb-system daemonset/metallb-speaker 120

# Wait for the webhook to be available
sleep 5

##############################################################################
# Apply address pool and L2 advertisement (with dynamic IP range)
##############################################################################
log "Applying IPAddressPool with range ${POOL_START} - ${POOL_END}..."

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: k3d-pool
  namespace: metallb-system
spec:
  addresses:
    - ${POOL_START}-${POOL_END}
  autoAssign: true
EOF

kubectl apply -f "${REPO_ROOT}/networking/metallb/manifests/l2-advertisement.yaml"

ok "MetalLB installed and configured"
log "LoadBalancer services will receive IPs from ${POOL_START}-${POOL_END}"
