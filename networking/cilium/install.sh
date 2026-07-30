#!/usr/bin/env bash
# install.sh — install Cilium CNI with kube-proxy replacement on k3d
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"
CILIUM_VERSION="${CILIUM_VERSION:-1.15.6}"

section "Installing Cilium ${CILIUM_VERSION}"

##############################################################################
# Get k8s API server IP (as seen from inside the Docker network)
# This is needed so Cilium can reach the API server without kube-proxy.
# We inspect the server-0 container's IP on the cluster Docker network.
##############################################################################

log "Detecting k3d cluster Docker network and API server IP..."

# The server node container name follows the k3d convention
SERVER_CONTAINER="k3d-${CLUSTER_NAME}-server-0"

# Get the Docker network name for this cluster (k3d names it k3d-<clustername>)
# We look for the first non-'host' network the server is attached to
DOCKER_NETWORK="k3d-${CLUSTER_NAME}"

# Get the IP of the server node on that network
K8S_API_HOST=$(docker inspect "${SERVER_CONTAINER}" \
  --format "{{(index .NetworkSettings.Networks \"${DOCKER_NETWORK}\").IPAddress}}" 2>/dev/null || true)

if [[ -z "${K8S_API_HOST}" ]]; then
  # Fallback: try the first network address
  K8S_API_HOST=$(docker inspect "${SERVER_CONTAINER}" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
fi

if [[ -z "${K8S_API_HOST}" ]]; then
  die "Could not determine k8s API server IP. Is the cluster running? (container: ${SERVER_CONTAINER})"
fi

K8S_API_PORT="6443"
log "k8s API server: ${K8S_API_HOST}:${K8S_API_PORT}"

##############################################################################
# Add Cilium Helm repo
##############################################################################
helm_repo_add cilium https://helm.cilium.io/

##############################################################################
# Install or upgrade Cilium
##############################################################################
log "Installing Cilium ${CILIUM_VERSION} into kube-system..."

helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set k8sServiceHost="${K8S_API_HOST}" \
  --set k8sServicePort="${K8S_API_PORT}" \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=true \
  --values "${REPO_ROOT}/networking/cilium/values.yaml" \
  --wait \
  --timeout 5m

ok "Cilium installed"

##############################################################################
# Wait for Cilium DaemonSet to be ready
##############################################################################
wait_for_rollout kube-system daemonset/cilium 300

##############################################################################
# Wait for Cilium operator
##############################################################################
wait_for_rollout kube-system deployment/cilium-operator 120

##############################################################################
# Apply default network policies
##############################################################################
log "Applying default Cilium network policies..."
kubectl apply -f "${REPO_ROOT}/networking/cilium/policies/allow-dns.yaml"
# Note: default-deny is not applied by default as it would block all traffic
# Apply it explicitly when you want to enforce a zero-trust posture:
# kubectl apply -f "${REPO_ROOT}/networking/cilium/policies/default-deny.yaml"

ok "Cilium setup complete"

##############################################################################
# Optional: run Cilium connectivity test
##############################################################################
if [[ "${CILIUM_CONNECTIVITY_TEST:-false}" == "true" ]]; then
  if command -v cilium &>/dev/null; then
    log "Running Cilium connectivity tests (this takes ~5 minutes)..."
    cilium connectivity test --test-namespace cilium-test || \
      warn "Connectivity tests had failures — check cilium status"
  else
    warn "CILIUM_CONNECTIVITY_TEST=true but cilium CLI not installed"
  fi
fi

section "Cilium Status"
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-operator
