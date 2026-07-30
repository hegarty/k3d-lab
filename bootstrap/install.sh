#!/usr/bin/env bash
# install.sh — bootstrap a full k3d-lab cluster with Cilium and Gateway API
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

CLUSTER_PROFILE="${CLUSTER_PROFILE:-single-node}"
CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"
CLUSTER_CONFIG="${REPO_ROOT}/clusters/${CLUSTER_PROFILE}.yaml"

section "k3d-lab Install — Profile: ${CLUSTER_PROFILE}"

##############################################################################
# Step 1: Prerequisites
##############################################################################
section "Step 1/7: Prerequisites"
bash "${REPO_ROOT}/bootstrap/prerequisites.sh"

##############################################################################
# Step 2: Create k3d cluster
##############################################################################
section "Step 2/7: Create k3d Cluster"

if [[ ! -f "${CLUSTER_CONFIG}" ]]; then
  die "Cluster config not found: ${CLUSTER_CONFIG}"
fi

if cluster_exists "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
  log "To recreate, run: bash bootstrap/reset.sh"
else
  log "Creating k3d cluster from: ${CLUSTER_CONFIG}"
  k3d cluster create \
    --config "${CLUSTER_CONFIG}" \
    --kubeconfig-update-default \
    --wait
  ok "Cluster '${CLUSTER_NAME}' created"
fi

# Switch to cluster context
CONTEXT="k3d-${CLUSTER_NAME}"
kubectl config use-context "${CONTEXT}"
ok "kubectl context: ${CONTEXT}"

##############################################################################
# Step 3: Wait for API server reachable (NOT node Ready — no CNI yet)
##############################################################################
section "Step 3/7: Wait for API Server"
log "Waiting for Kubernetes API server to be reachable..."
deadline=$(( $(date +%s) + 60 ))
until kubectl get nodes &>/dev/null; do
  if [[ $(date +%s) -gt ${deadline} ]]; then
    die "Kubernetes API server did not become reachable within 60s"
  fi
  sleep 2
done
ok "API server reachable"
log "Node status (NotReady is expected — no CNI installed yet):"
kubectl get nodes -o wide

##############################################################################
# Step 4: Install Cilium (CNI — nodes become Ready after this)
##############################################################################
section "Step 4/7: Install Cilium"
bash "${REPO_ROOT}/networking/cilium/install.sh"

log "Waiting for nodes to become Ready after Cilium install..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s
ok "All nodes ready"
kubectl get nodes -o wide

##############################################################################
# Step 5: Install Gateway API CRDs
##############################################################################
section "Step 5/7: Install Gateway API"
bash "${REPO_ROOT}/networking/gateway-api/install.sh"

##############################################################################
# Step 6: Deploy hello-world workload
##############################################################################
section "Step 6/7: Deploy hello-world workload"
bash "${REPO_ROOT}/workloads/hello-world/install.sh"

##############################################################################
# Step 7: Optional components
##############################################################################
section "Step 7/7: Optional Components"

if [[ "${INSTALL_METALLB:-false}" == "true" ]]; then
  log "Installing MetalLB..."
  bash "${REPO_ROOT}/networking/metallb/install.sh"
fi

if [[ "${INSTALL_OBSERVABILITY:-false}" == "true" ]]; then
  log "Installing observability stack..."
  bash "${REPO_ROOT}/observability/kube-prometheus-stack/install.sh"
  bash "${REPO_ROOT}/observability/loki/install.sh"
  bash "${REPO_ROOT}/observability/tempo/install.sh"
  bash "${REPO_ROOT}/observability/opentelemetry/install.sh"
fi

if [[ "${INSTALL_SECURITY:-false}" == "true" ]]; then
  log "Installing security stack..."
  bash "${REPO_ROOT}/security/cert-manager/install.sh"
  bash "${REPO_ROOT}/security/kyverno/install.sh"
  bash "${REPO_ROOT}/security/external-secrets/install.sh"
fi

if [[ "${SERVICE_MESH:-none}" == "istio" ]]; then
  log "Installing Istio..."
  bash "${REPO_ROOT}/service-mesh/istio/install.sh"
fi

if [[ "${INGRESS_PROVIDER:-cilium}" == "nginx" ]]; then
  log "Installing NGINX ingress controller..."
  bash "${REPO_ROOT}/ingress/nginx/install.sh"
fi

##############################################################################
# Validate
##############################################################################
section "Validation"
bash "${REPO_ROOT}/bootstrap/validate.sh"

##############################################################################
# Summary
##############################################################################
section "Install Complete"

ok "k3d-lab is ready!"
echo "" >&2
log "Cluster profile: ${CLUSTER_PROFILE}"
log "Cluster name:    ${CLUSTER_NAME}"
log "kubectl context: ${CONTEXT}"
echo "" >&2

case "${CLUSTER_PROFILE}" in
  single-node)
    log "Access services:"
    log "  http://localhost:8080  — HTTP ingress"
    log "  https://localhost:8443 — HTTPS ingress"
    log "  curl http://localhost:8080 — hello-world"
    ;;
  ha)
    log "Access services:"
    log "  http://localhost:8180  — HTTP ingress (via LB)"
    log "  https://localhost:8543 — HTTPS ingress"
    ;;
  market-dev)
    log "Access services:"
    log "  http://localhost:8280  — HTTP ingress"
    log "  http://localhost:3000  — Grafana"
    log "  http://localhost:16686 — Jaeger"
    log "  localhost:5000         — Local registry"
    ;;
esac

echo "" >&2
log "Hubble UI:  kubectl port-forward -n kube-system svc/hubble-ui 12000:80"
log "Doctor:     bash scripts/doctor.sh"
log "Info:       bash scripts/cluster-info.sh"
