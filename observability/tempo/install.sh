#!/usr/bin/env bash
# install.sh — install Grafana Tempo for distributed tracing
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

TEMPO_VERSION="${TEMPO_VERSION:-1.10.3}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

section "Installing Tempo v${TEMPO_VERSION}"

##############################################################################
# Add Grafana Helm repo
##############################################################################
helm_repo_add grafana https://grafana.github.io/helm-charts

ensure_namespace "${OBSERVABILITY_NAMESPACE}"

##############################################################################
# Install Tempo
##############################################################################
log "Installing Grafana Tempo (monolithic mode)..."
helm upgrade --install tempo grafana/tempo \
  --version "${TEMPO_VERSION}" \
  --namespace "${OBSERVABILITY_NAMESPACE}" \
  --values "${REPO_ROOT}/observability/tempo/values.yaml" \
  --timeout 10m \
  --wait

ok "Tempo installed"

wait_for_rollout "${OBSERVABILITY_NAMESPACE}" statefulset/tempo 300

section "Tempo Status"
kubectl get pods -n "${OBSERVABILITY_NAMESPACE}" -l app.kubernetes.io/name=tempo
kubectl get svc -n "${OBSERVABILITY_NAMESPACE}" -l app.kubernetes.io/name=tempo

ok "Tempo ready"
log "Tempo OTLP gRPC:    tempo.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:4317"
log "Tempo OTLP HTTP:    tempo.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:4318"
log "Tempo query HTTP:   tempo.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:3100"
log "Zipkin:             tempo.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:9411"
