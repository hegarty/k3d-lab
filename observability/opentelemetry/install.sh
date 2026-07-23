#!/usr/bin/env bash
# install.sh — install OpenTelemetry Collector
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

OPENTELEMETRY_VERSION="${OPENTELEMETRY_VERSION:-0.102.1}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

section "Installing OpenTelemetry Collector v${OPENTELEMETRY_VERSION}"

##############################################################################
# Add OpenTelemetry Helm repo
##############################################################################
helm_repo_add open-telemetry \
  https://open-telemetry.github.io/opentelemetry-helm-charts

ensure_namespace "${OBSERVABILITY_NAMESPACE}"

##############################################################################
# Install OTel Collector as DaemonSet
##############################################################################
log "Installing OpenTelemetry Collector (DaemonSet)..."
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --version "${OPENTELEMETRY_VERSION}" \
  --namespace "${OBSERVABILITY_NAMESPACE}" \
  --values "${REPO_ROOT}/observability/opentelemetry/values.yaml" \
  --timeout 5m \
  --wait

ok "OpenTelemetry Collector installed"

##############################################################################
# Apply standalone collector manifest (gateway mode for aggregation)
##############################################################################
log "Applying OTel gateway collector..."
kubectl apply -f "${REPO_ROOT}/observability/opentelemetry/collectors/collector.yaml"

##############################################################################
# Wait for readiness
##############################################################################
wait_for_rollout "${OBSERVABILITY_NAMESPACE}" daemonset/otel-collector 180

section "OpenTelemetry Status"
kubectl get pods -n "${OBSERVABILITY_NAMESPACE}" -l app.kubernetes.io/name=opentelemetry-collector

ok "OpenTelemetry Collector ready"
log "OTLP gRPC endpoint: otel-collector.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:4317"
log "OTLP HTTP endpoint: otel-collector.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:4318"
