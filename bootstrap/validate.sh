#!/usr/bin/env bash
# validate.sh — verify the cluster is healthy after install
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"
CONTEXT="k3d-${CLUSTER_NAME}"

PASS=0
FAIL=0
WARN=0

check_pass() { ok "$1"; (( PASS++ )) || true; }
check_fail() { err "$1"; (( FAIL++ )) || true; }
check_warn() { warn "$1"; (( WARN++ )) || true; }

K() { kubectl --context="${CONTEXT}" "$@"; }

section "k3d-lab Validation — Cluster: ${CLUSTER_NAME}"

##############################################################################
# Nodes
##############################################################################
section "Nodes"

node_count=$(K get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
not_ready=$(K get nodes --no-headers 2>/dev/null | grep -c "NotReady" || echo 0)

if [[ "${node_count}" -gt 0 ]]; then
  check_pass "${node_count} node(s) found"
else
  check_fail "No nodes found in cluster"
fi

if [[ "${not_ready}" -eq 0 ]]; then
  check_pass "All nodes are Ready"
else
  check_fail "${not_ready} node(s) are NotReady"
  K get nodes >&2
fi

##############################################################################
# System pods
##############################################################################
section "System Pods"

log "Checking kube-system pods..."
not_running=$(K get pods -n kube-system --no-headers 2>/dev/null | \
  grep -v "Running\|Completed" | grep -v "^$" | wc -l | tr -d ' ')

if [[ "${not_running}" -eq 0 ]]; then
  check_pass "All kube-system pods are Running/Completed"
else
  check_warn "${not_running} pod(s) in kube-system not Running:"
  K get pods -n kube-system --no-headers | grep -v "Running\|Completed" >&2 || true
fi

##############################################################################
# CoreDNS
##############################################################################
section "CoreDNS"

coredns_ready=$(K get pods -n kube-system -l k8s-app=kube-dns \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "${coredns_ready}" -ge 1 ]]; then
  check_pass "CoreDNS: ${coredns_ready} pod(s) running"
else
  check_fail "CoreDNS: no running pods found"
fi

# Test DNS resolution from a pod
log "Testing DNS resolution..."
if K run dns-test-$$ --image=busybox:1.36 --restart=Never --rm -it \
   --command -- nslookup kubernetes.default.svc.cluster.local \
   --timeout=30 &>/dev/null; then
  check_pass "DNS resolution: kubernetes.default.svc.cluster.local"
else
  check_warn "DNS resolution test inconclusive (pod exec may have timed out)"
fi

##############################################################################
# Cilium
##############################################################################
section "Cilium"

cilium_ds=$(K get daemonset -n kube-system cilium --no-headers 2>/dev/null | awk '{print $4}' || echo 0)
cilium_desired=$(K get daemonset -n kube-system cilium --no-headers 2>/dev/null | awk '{print $2}' || echo 0)

if [[ "${cilium_ds:-0}" == "${cilium_desired:-0}" ]] && [[ "${cilium_ds:-0}" -ge 1 ]]; then
  check_pass "Cilium DaemonSet: ${cilium_ds}/${cilium_desired} pods ready"
else
  check_fail "Cilium DaemonSet: ${cilium_ds:-0}/${cilium_desired:-0} pods ready"
  K get pods -n kube-system -l k8s-app=cilium >&2 || true
fi

if command -v cilium &>/dev/null; then
  log "Running cilium status..."
  if cilium --context="${CONTEXT}" status --wait --wait-duration 60s &>/dev/null; then
    check_pass "Cilium status: OK"
  else
    check_warn "Cilium status check had issues (may still be initializing)"
  fi
fi

# Hubble relay
hubble_ready=$(K get pods -n kube-system -l k8s-app=hubble-relay \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${hubble_ready}" -ge 1 ]]; then
  check_pass "Hubble Relay: running"
else
  check_warn "Hubble Relay: not running (may need --hubble in values)"
fi

##############################################################################
# Gateway API CRDs
##############################################################################
section "Gateway API"

gateway_crds=("gateways.gateway.networking.k8s.io" "httproutes.gateway.networking.k8s.io" "grpcroutes.gateway.networking.k8s.io")
for crd in "${gateway_crds[@]}"; do
  if K get crd "${crd}" &>/dev/null; then
    check_pass "CRD: ${crd}"
  else
    check_fail "CRD missing: ${crd}"
  fi
done

##############################################################################
# hello-world workload
##############################################################################
section "hello-world Workload"

hw_ready=$(K get pods -n hello-world -l app=hello-world \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${hw_ready}" -ge 1 ]]; then
  check_pass "hello-world: ${hw_ready} pod(s) running"
else
  check_warn "hello-world: no running pods (namespace may not exist yet)"
fi

##############################################################################
# Summary
##############################################################################
section "Validation Summary"

total=$(( PASS + FAIL + WARN ))
printf '\n' >&2
printf '  \033[0;32mPASS\033[0m: %d\n' "${PASS}" >&2
printf '  \033[0;33mWARN\033[0m: %d\n' "${WARN}" >&2
printf '  \033[0;31mFAIL\033[0m: %d\n' "${FAIL}" >&2
printf '  Total: %d checks\n\n' "${total}" >&2

if [[ "${FAIL}" -gt 0 ]]; then
  err "Validation FAILED: ${FAIL} critical issue(s)"
  err "Run: bash scripts/cluster-info.sh  for details"
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  warn "Validation passed with ${WARN} warning(s)"
  ok "Cluster is functional"
else
  ok "All validation checks passed!"
fi
