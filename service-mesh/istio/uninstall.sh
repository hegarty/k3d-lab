#!/usr/bin/env bash
# uninstall.sh — remove Istio from the cluster
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"

section "Uninstalling Istio"

# Remove Istio gateway
if helm status istio-ingressgateway -n istio-ingress &>/dev/null; then
  helm uninstall istio-ingressgateway -n istio-ingress --wait --timeout 2m
  ok "Istio gateway removed"
fi

# Remove istiod
if helm status istiod -n "${ISTIO_NAMESPACE}" &>/dev/null; then
  helm uninstall istiod -n "${ISTIO_NAMESPACE}" --wait --timeout 2m
  ok "istiod removed"
fi

# Remove istio-base (CRDs)
if helm status istio-base -n "${ISTIO_NAMESPACE}" &>/dev/null; then
  helm uninstall istio-base -n "${ISTIO_NAMESPACE}" --wait --timeout 2m
  ok "Istio base removed"
fi

# Clean up namespaces
kubectl delete namespace istio-ingress --ignore-not-found
kubectl delete namespace "${ISTIO_NAMESPACE}" --ignore-not-found

ok "Istio uninstalled"
