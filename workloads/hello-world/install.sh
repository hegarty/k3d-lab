#!/usr/bin/env bash
# install.sh — deploy the hello-world workload
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

WORKLOAD_DIR="${REPO_ROOT}/workloads/hello-world"

section "Deploying hello-world workload"

log "Applying namespace..."
kubectl apply -f "${WORKLOAD_DIR}/namespace.yaml"

log "Applying deployment..."
kubectl apply -f "${WORKLOAD_DIR}/deployment.yaml"

log "Applying service..."
kubectl apply -f "${WORKLOAD_DIR}/service.yaml"

log "Applying HTTPRoute..."
kubectl apply -f "${WORKLOAD_DIR}/httproute.yaml" || \
  warn "HTTPRoute apply failed — Gateway API CRDs may not be installed yet"

##############################################################################
# Wait for rollout
##############################################################################
wait_for_rollout hello-world deployment/hello-world 120

section "hello-world Status"
kubectl get all -n hello-world
echo ""
kubectl get httproute -n hello-world 2>/dev/null || true

ok "hello-world deployed"
log ""

PROFILE="${CLUSTER_PROFILE:-single-node}"
case "${PROFILE}" in
  single-node|market-dev)
    log "Test with curl:"
    log "  curl -H 'Host: hello-world.localhost' http://localhost:8080"
    log "  curl http://localhost:8080  (if gateway routes to default backend)"
    ;;
  ha)
    log "Test with curl:"
    log "  curl -H 'Host: hello-world.localhost' http://localhost:8180"
    ;;
esac

log ""
log "Or port-forward directly:"
log "  kubectl port-forward -n hello-world svc/hello-world 8888:8080"
log "  curl http://localhost:8888/health"
