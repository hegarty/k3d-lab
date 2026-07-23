#!/usr/bin/env bash
# install.sh — install kube-prometheus-stack (Prometheus + Grafana + AlertManager)
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

PROMETHEUS_STACK_VERSION="${PROMETHEUS_STACK_VERSION:-61.3.2}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

section "Installing kube-prometheus-stack v${PROMETHEUS_STACK_VERSION}"

##############################################################################
# Add repo and create namespace
##############################################################################
helm_repo_add prometheus-community \
  https://prometheus-community.github.io/helm-charts

ensure_namespace "${OBSERVABILITY_NAMESPACE}"

##############################################################################
# Install
##############################################################################
log "Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "${PROMETHEUS_STACK_VERSION}" \
  --namespace "${OBSERVABILITY_NAMESPACE}" \
  --values "${REPO_ROOT}/observability/kube-prometheus-stack/values.yaml" \
  --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD:-prom-operator}" \
  --timeout 10m \
  --wait

ok "kube-prometheus-stack installed"

##############################################################################
# Wait for components
##############################################################################
wait_for_rollout "${OBSERVABILITY_NAMESPACE}" deployment/kube-prometheus-stack-grafana 300
wait_for_rollout "${OBSERVABILITY_NAMESPACE}" deployment/kube-prometheus-stack-prometheus-operator 180

section "kube-prometheus-stack Status"
kubectl get pods -n "${OBSERVABILITY_NAMESPACE}"
echo ""

ok "Observability stack ready"
log "Access Grafana:    kubectl port-forward -n ${OBSERVABILITY_NAMESPACE} svc/kube-prometheus-stack-grafana 3000:80"
log "  URL:             http://localhost:3000"
log "  Credentials:     admin / ${GRAFANA_ADMIN_PASSWORD:-prom-operator}"
log ""
log "Access Prometheus: kubectl port-forward -n ${OBSERVABILITY_NAMESPACE} svc/kube-prometheus-stack-prometheus 9090:9090"
log "  URL:             http://localhost:9090"
