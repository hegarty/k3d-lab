#!/usr/bin/env bash
# install.sh — deploy the OpenTelemetry demo application
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
CONTEXT="k3d-${CLUSTER_NAME}"

section "Deploying OpenTelemetry Demo"

##############################################################################
# Verify observability stack is present
##############################################################################
if ! kubectl --context="${CONTEXT}" get namespace observability &>/dev/null; then
  err "Namespace 'observability' not found."
  err "Run: make observability-install"
  exit 1
fi

if ! kubectl --context="${CONTEXT}" get deployment otel-gateway -n observability &>/dev/null; then
  err "otel-gateway not found in observability namespace."
  err "Run: make observability-install"
  exit 1
fi

##############################################################################
# Deploy
##############################################################################
log "Applying otel-demo namespace..."
kubectl --context="${CONTEXT}" apply -f "${REPO_ROOT}/workloads/otel-demo/namespace.yaml"

log "Applying otel-demo workloads..."
kubectl --context="${CONTEXT}" apply -f "${REPO_ROOT}/workloads/otel-demo/otel-demo.yaml"

##############################################################################
# Wait for readiness
##############################################################################
wait_for_rollout otel-demo deployment/productcatalogservice 180
wait_for_rollout otel-demo deployment/frontend 180

##############################################################################
# Status
##############################################################################
section "otel-demo Status"
kubectl --context="${CONTEXT}" get pods -n otel-demo
echo ""
kubectl --context="${CONTEXT}" get svc -n otel-demo
echo ""
kubectl --context="${CONTEXT}" get httproute -n otel-demo

ok "otel-demo deployed"
log "Access the frontend via port-forward:"
log "  kubectl port-forward -n otel-demo svc/frontend 8888:8080"
log "  open http://localhost:8888"
log ""
log "Traces will appear in Grafana → Explore → Tempo within ~30s of traffic"
log "  kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80"
log "  open http://localhost:3000 (admin / prom-operator)"
