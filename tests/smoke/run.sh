#!/usr/bin/env bash
# smoke/run.sh — basic cluster health smoke tests
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"
CONTEXT="k3d-${CLUSTER_NAME}"

PASS=0
FAIL=0

t_pass() { ok "PASS: $1"; (( PASS++ )) || true; }
t_fail() { err "FAIL: $1"; (( FAIL++ )) || true; }
K() { kubectl --context="${CONTEXT}" "$@"; }

section "Smoke Tests — Cluster: ${CLUSTER_NAME}"

##############################################################################
# Test: cluster is reachable
##############################################################################
if K get nodes &>/dev/null; then
  t_pass "Cluster is reachable"
else
  t_fail "Cluster is not reachable — check kubectl context"
  exit 1
fi

##############################################################################
# Test: all nodes are Ready
##############################################################################
not_ready=$(K get nodes --no-headers | grep -c "NotReady" || echo 0)
if [[ "${not_ready}" -eq 0 ]]; then
  t_pass "All nodes are Ready"
else
  t_fail "Nodes not Ready: ${not_ready} node(s)"
fi

##############################################################################
# Test: CoreDNS is running
##############################################################################
coredns=$(K get pods -n kube-system -l k8s-app=kube-dns \
  --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')
if [[ "${coredns}" -ge 1 ]]; then
  t_pass "CoreDNS: ${coredns} pod(s) running"
else
  t_fail "CoreDNS: no running pods"
fi

##############################################################################
# Test: Cilium DaemonSet is running
##############################################################################
cilium_ready=$(K get ds -n kube-system cilium \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
cilium_desired=$(K get ds -n kube-system cilium \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
if [[ "${cilium_ready}" -eq "${cilium_desired}" ]] && [[ "${cilium_ready}" -ge 1 ]]; then
  t_pass "Cilium: ${cilium_ready}/${cilium_desired} pods ready"
else
  t_fail "Cilium: ${cilium_ready}/${cilium_desired} pods ready"
fi

##############################################################################
# Test: hello-world deployment is ready
##############################################################################
hw_ready=$(K get deployment -n hello-world hello-world \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
hw_desired=$(K get deployment -n hello-world hello-world \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
if [[ "${hw_ready:-0}" -ge 1 ]]; then
  t_pass "hello-world: ${hw_ready}/${hw_desired} replicas ready"
else
  t_fail "hello-world: not ready (${hw_ready:-0}/${hw_desired:-0})"
fi

##############################################################################
# Test: hello-world service responds via port-forward
##############################################################################
log "Testing hello-world HTTP response via port-forward..."
# Start port-forward in background
kubectl --context="${CONTEXT}" port-forward -n hello-world svc/hello-world 18080:8080 &>/dev/null &
PF_PID=$!
sleep 3

if curl -sf --max-time 5 http://localhost:18080/health &>/dev/null; then
  t_pass "hello-world HTTP health check"
else
  t_fail "hello-world HTTP health check failed"
fi

kill "${PF_PID}" 2>/dev/null || true
wait "${PF_PID}" 2>/dev/null || true

##############################################################################
# Test: Gateway API CRDs installed
##############################################################################
for crd in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io; do
  if K get crd "${crd}" &>/dev/null; then
    t_pass "CRD: ${crd}"
  else
    t_fail "CRD missing: ${crd}"
  fi
done

##############################################################################
# Test: local-path StorageClass exists
##############################################################################
if K get storageclass local-path &>/dev/null; then
  t_pass "StorageClass: local-path"
else
  t_fail "StorageClass: local-path not found"
fi

##############################################################################
# Test: can create and delete a PVC
##############################################################################
log "Testing PVC creation..."
PVC_NAME="smoke-test-pvc-$$"
K apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Mi
EOF

sleep 3
PVC_STATUS=$(K get pvc "${PVC_NAME}" -n default \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

# PVC may be Pending (WaitForFirstConsumer) or Bound
if [[ "${PVC_STATUS}" == "Bound" ]] || [[ "${PVC_STATUS}" == "Pending" ]]; then
  t_pass "PVC creation: ${PVC_STATUS}"
else
  t_fail "PVC creation failed: status=${PVC_STATUS}"
fi

K delete pvc "${PVC_NAME}" -n default --ignore-not-found &>/dev/null || true

##############################################################################
# Summary
##############################################################################
section "Smoke Test Summary"
printf '  \033[0;32mPASS\033[0m: %d\n' "${PASS}" >&2
printf '  \033[0;31mFAIL\033[0m: %d\n' "${FAIL}" >&2
printf '  Total: %d tests\n' "$(( PASS + FAIL ))" >&2

if [[ "${FAIL}" -gt 0 ]]; then
  err "Smoke tests FAILED: ${FAIL} failure(s)"
  exit 1
else
  ok "All smoke tests passed!"
fi
