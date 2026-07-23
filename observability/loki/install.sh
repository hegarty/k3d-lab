#!/usr/bin/env bash
# install.sh — install Loki for log aggregation
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

LOKI_VERSION="${LOKI_VERSION:-6.6.4}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

section "Installing Loki v${LOKI_VERSION}"

##############################################################################
# Add Grafana Helm repo
##############################################################################
helm_repo_add grafana https://grafana.github.io/helm-charts

ensure_namespace "${OBSERVABILITY_NAMESPACE}"

##############################################################################
# Install Loki
##############################################################################
log "Installing Loki (single binary mode)..."
helm upgrade --install loki grafana/loki \
  --version "${LOKI_VERSION}" \
  --namespace "${OBSERVABILITY_NAMESPACE}" \
  --values "${REPO_ROOT}/observability/loki/values.yaml" \
  --timeout 5m \
  --wait

ok "Loki installed"

##############################################################################
# Deploy Promtail as log collector
##############################################################################
log "Installing Promtail DaemonSet..."
helm upgrade --install promtail grafana/promtail \
  --namespace "${OBSERVABILITY_NAMESPACE}" \
  --set config.lokiAddress="http://loki-gateway.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:80/loki/api/v1/push" \
  --set resources.requests.cpu=10m \
  --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=128Mi \
  --timeout 3m \
  --wait

ok "Promtail DaemonSet installed"

wait_for_rollout "${OBSERVABILITY_NAMESPACE}" statefulset/loki 300

section "Loki Status"
kubectl get pods -n "${OBSERVABILITY_NAMESPACE}" -l app.kubernetes.io/name=loki
kubectl get pods -n "${OBSERVABILITY_NAMESPACE}" -l app.kubernetes.io/name=promtail

ok "Loki ready"
log "Loki endpoint: http://loki-gateway.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:80"
log "Query logs:    kubectl port-forward -n ${OBSERVABILITY_NAMESPACE} svc/loki-gateway 3100:80"
