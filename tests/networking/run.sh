#!/usr/bin/env bash
# networking/run.sh — network policy and connectivity tests
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
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

section "Networking Tests — Cluster: ${CLUSTER_NAME}"

##############################################################################
# Setup: deploy network-test workloads if not present
##############################################################################
log "Ensuring network-test namespace and pods..."
K apply -f "${REPO_ROOT}/workloads/network-test/namespace.yaml" &>/dev/null
K apply -f "${REPO_ROOT}/workloads/network-test/test-pods.yaml" &>/dev/null

# Wait for pods
log "Waiting for test pods..."
DEADLINE=$(( $(date +%s) + 120 ))
until K get pod nettest-client -n network-test \
  -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; do
  if [[ $(date +%s) -gt "${DEADLINE}" ]]; then
    t_fail "nettest-client pod did not start within 120s"
    break
  fi
  sleep 5
done

CLIENT_RUNNING=$(K get pod nettest-client -n network-test \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
SERVER_RUNNING=$(K get pod nettest-server -n network-test \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

##############################################################################
# Test: DNS resolution from client pod
##############################################################################
log "Testing DNS resolution..."
if K exec nettest-client -n network-test -- \
  nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
  t_pass "DNS: kubernetes.default.svc.cluster.local resolves"
else
  t_fail "DNS: kubernetes.default.svc.cluster.local does not resolve"
fi

if K exec nettest-client -n network-test -- \
  nslookup nettest-server.network-test.svc.cluster.local &>/dev/null; then
  t_pass "DNS: nettest-server service resolves"
else
  t_fail "DNS: nettest-server service does not resolve"
fi

##############################################################################
# Test: client can reach server within same namespace (no policy yet)
##############################################################################
log "Testing client → server connectivity (intra-namespace)..."
if K exec nettest-client -n network-test -- \
  curl -sf --max-time 5 http://nettest-server.network-test.svc.cluster.local:8080/health &>/dev/null; then
  t_pass "Intra-namespace: client → server HTTP"
else
  t_fail "Intra-namespace: client → server HTTP failed"
fi

##############################################################################
# Test: client can reach hello-world in different namespace
##############################################################################
log "Testing cross-namespace connectivity (before policy)..."
if K exec nettest-client -n network-test -- \
  curl -sf --max-time 5 http://hello-world.hello-world.svc.cluster.local:8080/health &>/dev/null; then
  t_pass "Cross-namespace: network-test → hello-world HTTP (permitted)"
else
  warn "Cross-namespace: network-test → hello-world failed (may be blocked by policy)"
fi

##############################################################################
# Test: Apply network policies and verify enforcement
##############################################################################
log "Applying network policies..."
K apply -f "${REPO_ROOT}/workloads/network-test/network-policies.yaml" &>/dev/null
sleep 5

# After policy: isolated pod should not reach server
log "Testing isolated pod cannot reach server (policy enforcement)..."
if K exec nettest-isolated -n network-test -- \
  curl -sf --max-time 5 http://nettest-server.network-test.svc.cluster.local:8080/health &>/dev/null; then
  t_fail "Policy: isolated pod reached server (should be DENIED)"
else
  t_pass "Policy: isolated pod correctly denied access to server"
fi

# After policy: client should still reach server
log "Testing client can still reach server after policy..."
if K exec nettest-client -n network-test -- \
  curl -sf --max-time 5 http://nettest-server.network-test.svc.cluster.local:8080/health &>/dev/null; then
  t_pass "Policy: client → server still permitted"
else
  t_fail "Policy: client → server incorrectly blocked"
fi

##############################################################################
# Test: Cilium network policies
##############################################################################
log "Checking Cilium CiliumNetworkPolicy CRD..."
if K get crd ciliumnetworkpolicies.cilium.io &>/dev/null; then
  t_pass "CiliumNetworkPolicy CRD exists"
else
  t_fail "CiliumNetworkPolicy CRD missing"
fi

##############################################################################
# Test: Hubble relay is running
##############################################################################
hubble_ready=$(K get pods -n kube-system -l k8s-app=hubble-relay \
  --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')
if [[ "${hubble_ready}" -ge 1 ]]; then
  t_pass "Hubble Relay: running"
else
  warn "Hubble Relay: not running"
fi

##############################################################################
# Test: Gateway API HTTPRoute programmed
##############################################################################
log "Checking hello-world HTTPRoute status..."
ROUTE_STATUS=$(K get httproute hello-world -n hello-world \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "Unknown")
if [[ "${ROUTE_STATUS}" == "True" ]]; then
  t_pass "HTTPRoute: hello-world Accepted"
else
  warn "HTTPRoute: hello-world status=${ROUTE_STATUS} (may be pending)"
fi

##############################################################################
# Cleanup
##############################################################################
log "Cleaning up network policy test resources..."
K delete -f "${REPO_ROOT}/workloads/network-test/network-policies.yaml" &>/dev/null || true
K delete pod nettest-client nettest-server nettest-isolated -n network-test --ignore-not-found &>/dev/null || true

##############################################################################
# Summary
##############################################################################
section "Networking Test Summary"
printf '  \033[0;32mPASS\033[0m: %d\n' "${PASS}" >&2
printf '  \033[0;31mFAIL\033[0m: %d\n' "${FAIL}" >&2
printf '  Total: %d tests\n' "$(( PASS + FAIL ))" >&2

if [[ "${FAIL}" -gt 0 ]]; then
  err "Networking tests FAILED: ${FAIL} failure(s)"
  exit 1
else
  ok "All networking tests passed!"
fi
