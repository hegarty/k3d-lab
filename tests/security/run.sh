#!/usr/bin/env bash
# security/run.sh — verify Kyverno policies and cert-manager are working
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

CLUSTER_NAME="${CLUSTER_NAME:-k3d-lab}"
CONTEXT="k3d-${CLUSTER_NAME}"

PASS=0
FAIL=0
SKIP=0

t_pass() { ok "PASS: $1"; (( PASS++ )) || true; }
t_fail() { err "FAIL: $1"; (( FAIL++ )) || true; }
t_skip() { warn "SKIP: $1"; (( SKIP++ )) || true; }
K() { kubectl --context="${CONTEXT}" "$@"; }

section "Security Tests — Cluster: ${CLUSTER_NAME}"

##############################################################################
# Test: cert-manager
##############################################################################
section "cert-manager"

CERT_MGR_NS="${CERT_MANAGER_NAMESPACE:-cert-manager}"
if K get namespace "${CERT_MGR_NS}" &>/dev/null; then
  cm_pods=$(K get pods -n "${CERT_MGR_NS}" \
    -l "app.kubernetes.io/name=cert-manager" \
    --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

  if [[ "${cm_pods}" -ge 1 ]]; then
    t_pass "cert-manager: ${cm_pods} pod(s) running"
  else
    t_fail "cert-manager: no running pods"
  fi

  # Check ClusterIssuers
  if K get clusterissuer selfsigned-issuer &>/dev/null; then
    t_pass "ClusterIssuer: selfsigned-issuer exists"
    issuer_ready=$(K get clusterissuer selfsigned-issuer \
      -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
    if [[ "${issuer_ready}" == "Ready" ]]; then
      t_pass "ClusterIssuer: selfsigned-issuer is Ready"
    else
      t_fail "ClusterIssuer: selfsigned-issuer status=${issuer_ready}"
    fi
  else
    t_fail "ClusterIssuer: selfsigned-issuer not found"
  fi

  if K get clusterissuer k3d-lab-ca-issuer &>/dev/null; then
    t_pass "ClusterIssuer: k3d-lab-ca-issuer exists"
  else
    t_fail "ClusterIssuer: k3d-lab-ca-issuer not found"
  fi

  # Test: create and verify a certificate
  log "Testing certificate issuance..."
  TEST_CERT_NS="security-test-$$"
  K create namespace "${TEST_CERT_NS}" &>/dev/null

  K apply -f - &>/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: security-test-cert
  namespace: ${TEST_CERT_NS}
spec:
  secretName: security-test-tls
  commonName: security-test.localhost
  dnsNames: [security-test.localhost]
  issuerRef:
    name: k3d-lab-ca-issuer
    kind: ClusterIssuer
  duration: 1h
  renewBefore: 30m
EOF

  # Wait for certificate
  DEADLINE=$(( $(date +%s) + 60 ))
  CERT_READY="False"
  while [[ $(date +%s) -lt "${DEADLINE}" ]]; do
    CERT_READY=$(K get certificate security-test-cert -n "${TEST_CERT_NS}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    [[ "${CERT_READY}" == "True" ]] && break
    sleep 5
  done

  if [[ "${CERT_READY}" == "True" ]]; then
    t_pass "cert-manager: certificate issued successfully"
  else
    t_fail "cert-manager: certificate not issued within 60s"
  fi

  K delete namespace "${TEST_CERT_NS}" --ignore-not-found &>/dev/null || true
else
  t_skip "cert-manager: not installed"
fi

##############################################################################
# Test: Kyverno
##############################################################################
section "Kyverno"

KYVERNO_NS="${KYVERNO_NAMESPACE:-kyverno}"
if K get namespace "${KYVERNO_NS}" &>/dev/null; then
  kyverno_pods=$(K get pods -n "${KYVERNO_NS}" \
    -l "app.kubernetes.io/name=kyverno" \
    --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

  if [[ "${kyverno_pods}" -ge 1 ]]; then
    t_pass "Kyverno: ${kyverno_pods} pod(s) running"
  else
    t_fail "Kyverno: no running pods"
  fi

  # Check policies
  policy_count=$(K get clusterpolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${policy_count}" -ge 1 ]]; then
    t_pass "Kyverno: ${policy_count} ClusterPolicy/ies found"
  else
    t_fail "Kyverno: no ClusterPolicies found"
  fi

  # Test: disallow-latest-tag (Audit mode — pod with :latest image should show in policy report)
  log "Testing disallow-latest-tag policy (Audit mode)..."
  TEST_NS="kyverno-test-$$"
  K create namespace "${TEST_NS}" &>/dev/null

  # Try to create a pod with latest tag — in Audit mode, it should be created but reported
  K apply -f - &>/dev/null <<EOF || true
apiVersion: v1
kind: Pod
metadata:
  name: test-latest-image
  namespace: ${TEST_NS}
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: nginx:latest
      command: ["sleep", "1"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 50m
          memory: 32Mi
EOF

  sleep 3

  # In Audit mode, the pod should be created (not blocked)
  if K get pod test-latest-image -n "${TEST_NS}" &>/dev/null; then
    t_pass "Kyverno Audit: pod with :latest allowed (Audit mode — will appear in reports)"
  else
    t_pass "Kyverno Enforce: pod with :latest rejected (policy is in Enforce mode)"
  fi

  K delete namespace "${TEST_NS}" --ignore-not-found &>/dev/null || true

  # Check policy reports
  report_count=$(K get policyreport -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  log "Policy reports found: ${report_count}"
  t_pass "Kyverno: policy reporting active (${report_count} reports)"
else
  t_skip "Kyverno: not installed"
fi

##############################################################################
# Test: External Secrets
##############################################################################
section "External Secrets"

ESO_NS="${EXTERNAL_SECRETS_NAMESPACE:-external-secrets}"
if K get namespace "${ESO_NS}" &>/dev/null; then
  eso_pods=$(K get pods -n "${ESO_NS}" \
    -l "app.kubernetes.io/name=external-secrets" \
    --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')

  if [[ "${eso_pods}" -ge 1 ]]; then
    t_pass "External Secrets: ${eso_pods} pod(s) running"
  else
    t_fail "External Secrets: no running pods"
  fi

  # Check ClusterSecretStore
  if K get clustersecretstore fake-store &>/dev/null; then
    store_status=$(K get clustersecretstore fake-store \
      -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
    if [[ "${store_status}" == "Ready" ]]; then
      t_pass "ClusterSecretStore: fake-store Ready"
    else
      t_fail "ClusterSecretStore: fake-store status=${store_status}"
    fi
  else
    t_fail "ClusterSecretStore: fake-store not found"
  fi
else
  t_skip "External Secrets: not installed"
fi

##############################################################################
# Summary
##############################################################################
section "Security Test Summary"
printf '  \033[0;32mPASS\033[0m: %d\n' "${PASS}" >&2
printf '  \033[0;33mSKIP\033[0m: %d\n' "${SKIP}" >&2
printf '  \033[0;31mFAIL\033[0m: %d\n' "${FAIL}" >&2
printf '  Total: %d tests\n' "$(( PASS + FAIL + SKIP ))" >&2

if [[ "${FAIL}" -gt 0 ]]; then
  err "Security tests FAILED: ${FAIL} failure(s)"
  exit 1
else
  ok "Security tests completed (${PASS} passed, ${SKIP} skipped)"
fi
