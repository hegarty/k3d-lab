#!/usr/bin/env bash
# observability/run.sh — verify Prometheus, Grafana, Loki, Tempo are operational
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"
CONTEXT="k3d-${CLUSTER_NAME}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"

PASS=0
FAIL=0
SKIP=0

t_pass() { ok "PASS: $1"; (( PASS++ )) || true; }
t_fail() { err "FAIL: $1"; (( FAIL++ )) || true; }
t_skip() { warn "SKIP: $1"; (( SKIP++ )) || true; }
K() { kubectl --context="${CONTEXT}" "$@"; }

section "Observability Tests — Cluster: ${CLUSTER_NAME}"

##############################################################################
# Check observability namespace
##############################################################################
if ! K get namespace "${OBSERVABILITY_NAMESPACE}" &>/dev/null; then
  warn "Namespace '${OBSERVABILITY_NAMESPACE}' not found"
  warn "Run: make observability-install  to install the observability stack"
  t_skip "Observability stack not installed"
  exit 0
fi

##############################################################################
# Test: Prometheus is running
##############################################################################
prom_pods=$(K get pods -n "${OBSERVABILITY_NAMESPACE}" \
  -l "app.kubernetes.io/name=prometheus" \
  --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

if [[ "${prom_pods}" -ge 1 ]]; then
  t_pass "Prometheus: ${prom_pods} pod(s) running"

  # Test Prometheus API
  log "Testing Prometheus API via port-forward..."
  kubectl --context="${CONTEXT}" port-forward \
    -n "${OBSERVABILITY_NAMESPACE}" \
    svc/kube-prometheus-stack-prometheus 19090:9090 &>/dev/null &
  PF_PID=$!
  sleep 3

  PROM_STATUS=$(curl -sf --max-time 5 \
    http://localhost:19090/-/ready 2>/dev/null || echo "error")
  if echo "${PROM_STATUS}" | grep -qi "ready\|Prometheus is Ready"; then
    t_pass "Prometheus API: ready"
  else
    # Try the API status endpoint
    PROM_JSON=$(curl -sf --max-time 5 \
      "http://localhost:19090/api/v1/status/runtimeinfo" 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
    if [[ "${PROM_JSON}" == "success" ]]; then
      t_pass "Prometheus API: responding"
    else
      t_fail "Prometheus API: not responding"
    fi
  fi

  # Test: query returns data
  METRIC_COUNT=$(curl -sf --max-time 5 \
    "http://localhost:19090/api/v1/query?query=up" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{}).get('result',[])))" \
    2>/dev/null || echo 0)
  if [[ "${METRIC_COUNT}" -gt 0 ]]; then
    t_pass "Prometheus: ${METRIC_COUNT} 'up' series found"
  else
    t_fail "Prometheus: no 'up' metrics returned"
  fi

  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
else
  t_fail "Prometheus: no running pods"
fi

##############################################################################
# Test: Grafana is running
##############################################################################
grafana_pods=$(K get pods -n "${OBSERVABILITY_NAMESPACE}" \
  -l "app.kubernetes.io/name=grafana" \
  --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

if [[ "${grafana_pods}" -ge 1 ]]; then
  t_pass "Grafana: ${grafana_pods} pod(s) running"

  log "Testing Grafana API..."
  kubectl --context="${CONTEXT}" port-forward \
    -n "${OBSERVABILITY_NAMESPACE}" \
    svc/kube-prometheus-stack-grafana 13000:80 &>/dev/null &
  GF_PID=$!
  sleep 3

  GF_STATUS=$(curl -sf --max-time 5 \
    http://localhost:13000/api/health 2>/dev/null || echo "error")
  if echo "${GF_STATUS}" | grep -q "ok\|database"; then
    t_pass "Grafana API: healthy"
  else
    t_fail "Grafana API: not responding"
  fi

  kill "${GF_PID}" 2>/dev/null || true
  wait "${GF_PID}" 2>/dev/null || true
else
  t_fail "Grafana: no running pods"
fi

##############################################################################
# Test: Loki is running
##############################################################################
loki_pods=$(K get pods -n "${OBSERVABILITY_NAMESPACE}" \
  -l "app.kubernetes.io/name=loki" \
  --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

if [[ "${loki_pods}" -ge 1 ]]; then
  t_pass "Loki: ${loki_pods} pod(s) running"

  log "Testing Loki ready endpoint..."
  kubectl --context="${CONTEXT}" port-forward \
    -n "${OBSERVABILITY_NAMESPACE}" \
    svc/loki-gateway 13100:80 &>/dev/null &
  LK_PID=$!
  sleep 3

  LK_READY=$(curl -sf --max-time 5 http://localhost:13100/ready 2>/dev/null || echo "error")
  if echo "${LK_READY}" | grep -qi "ready"; then
    t_pass "Loki: ready"
  else
    t_fail "Loki: not ready (response: ${LK_READY:0:50})"
  fi

  kill "${LK_PID}" 2>/dev/null || true
  wait "${LK_PID}" 2>/dev/null || true
else
  t_skip "Loki: not installed"
fi

##############################################################################
# Test: Tempo is running
##############################################################################
tempo_pods=$(K get pods -n "${OBSERVABILITY_NAMESPACE}" \
  -l "app.kubernetes.io/name=tempo" \
  --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

if [[ "${tempo_pods}" -ge 1 ]]; then
  t_pass "Tempo: ${tempo_pods} pod(s) running"

  log "Testing Tempo ready endpoint..."
  kubectl --context="${CONTEXT}" port-forward \
    -n "${OBSERVABILITY_NAMESPACE}" \
    svc/tempo 13200:3100 &>/dev/null &
  TP_PID=$!
  sleep 3

  TP_READY=$(curl -sf --max-time 5 http://localhost:13200/ready 2>/dev/null || echo "error")
  if echo "${TP_READY}" | grep -qi "ready"; then
    t_pass "Tempo: ready"
  else
    t_fail "Tempo: not ready (response: ${TP_READY:0:50})"
  fi

  kill "${TP_PID}" 2>/dev/null || true
  wait "${TP_PID}" 2>/dev/null || true
else
  t_skip "Tempo: not installed"
fi

##############################################################################
# Test: OTel Collector is running
##############################################################################
otel_pods=$(K get pods -n "${OBSERVABILITY_NAMESPACE}" \
  -l "app.kubernetes.io/name=opentelemetry-collector" \
  --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

if [[ "${otel_pods}" -ge 1 ]]; then
  t_pass "OTel Collector: ${otel_pods} pod(s) running"
else
  t_skip "OTel Collector: not installed"
fi

##############################################################################
# Summary
##############################################################################
section "Observability Test Summary"
printf '  \033[0;32mPASS\033[0m: %d\n' "${PASS}" >&2
printf '  \033[0;33mSKIP\033[0m: %d\n' "${SKIP}" >&2
printf '  \033[0;31mFAIL\033[0m: %d\n' "${FAIL}" >&2
printf '  Total: %d tests\n' "$(( PASS + FAIL + SKIP ))" >&2

if [[ "${FAIL}" -gt 0 ]]; then
  err "Observability tests FAILED: ${FAIL} failure(s)"
  exit 1
else
  ok "Observability tests completed (${PASS} passed, ${SKIP} skipped)"
fi
