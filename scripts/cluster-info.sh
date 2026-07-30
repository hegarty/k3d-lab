#!/usr/bin/env bash
# cluster-info.sh — display cluster status and component summary
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"
CONTEXT="k3d-${CLUSTER_NAME}"

section "k3d-lab Cluster Info"

# k3d clusters
log "k3d clusters:"
k3d cluster list 2>/dev/null || warn "k3d not found or no clusters"

# kubectl context
log "Current kubectl context: $(kubectl config current-context 2>/dev/null || echo 'none')"

echo ""
section "Nodes"
kubectl --context="${CONTEXT}" get nodes -o wide 2>/dev/null || warn "Cannot reach cluster"

echo ""
section "System Pods"
kubectl --context="${CONTEXT}" get pods -n kube-system 2>/dev/null || true

echo ""
section "Helm Releases"
helm list -A --kube-context="${CONTEXT}" 2>/dev/null || warn "No helm releases or helm not available"

echo ""
section "Namespaces"
kubectl --context="${CONTEXT}" get namespaces 2>/dev/null || true

echo ""
section "Gateway API Resources"
if kubectl --context="${CONTEXT}" get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  kubectl --context="${CONTEXT}" get gateways,httproutes -A 2>/dev/null || true
else
  warn "Gateway API CRDs not installed"
fi

echo ""
section "Services with External IPs / LoadBalancer"
kubectl --context="${CONTEXT}" get svc -A --field-selector='spec.type=LoadBalancer' 2>/dev/null || true

echo ""
section "Cilium Status"
if command -v cilium &>/dev/null; then
  cilium --context="${CONTEXT}" status 2>/dev/null || warn "Cilium CLI error"
else
  warn "cilium CLI not installed — skipping cilium status"
  kubectl --context="${CONTEXT}" get pods -n kube-system -l k8s-app=cilium 2>/dev/null || true
fi

echo ""
section "Port Mappings"
echo "Profile: ${CLUSTER_PROFILE:-single-node}"
case "${CLUSTER_PROFILE:-single-node}" in
  single-node)
    echo "  http://localhost:8080  → port 80 (ingress)"
    echo "  https://localhost:8443 → port 443 (ingress)"
    echo "  http://localhost:9090  → port 9090 (prometheus direct)"
    ;;
  ha)
    echo "  http://localhost:8180  → port 80 (ingress via LB)"
    echo "  https://localhost:8543 → port 443 (ingress via LB)"
    ;;
  market-dev)
    echo "  http://localhost:8280  → port 80 (ingress)"
    echo "  https://localhost:8643 → port 443 (ingress)"
    echo "  http://localhost:16686 → port 16686 (Jaeger)"
    echo "  http://localhost:3000  → port 3000 (Grafana)"
    echo "  http://localhost:5000  → registry"
    ;;
esac

echo ""
ok "Cluster info complete"
