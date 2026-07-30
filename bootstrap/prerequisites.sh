#!/usr/bin/env bash
# prerequisites.sh — verify all required tools are installed and Docker is ready
set -Eeuo pipefail

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

section "Checking Prerequisites"

PASS=0
FAIL=0
WARN=0

check_pass() { ok "$1"; (( PASS++ )) || true; }
check_fail() { err "$1"; (( FAIL++ )) || true; }
check_warn() { warn "$1"; (( WARN++ )) || true; }

##############################################################################
# Required tools
##############################################################################

log "Checking required tools..."

# docker
if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
  check_pass "docker ${DOCKER_VER}"
else
  check_fail "docker: not found — install Docker Desktop from https://www.docker.com/products/docker-desktop/"
fi

# k3d
if command -v k3d &>/dev/null; then
  K3D_VER=$(k3d version 2>&1 | grep "k3d version" | awk '{print $3}')
  check_pass "k3d ${K3D_VER}"
else
  check_fail "k3d: not found — install with: brew install k3d  OR  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
fi

# kubectl
if command -v kubectl &>/dev/null; then
  KUBECTL_VER=$(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | awk '{print $2}')
  check_pass "kubectl ${KUBECTL_VER}"
else
  check_fail "kubectl: not found — install with: brew install kubectl"
fi

# helm
if command -v helm &>/dev/null; then
  HELM_VER=$(helm version --short 2>/dev/null | tr -d '"')
  check_pass "helm ${HELM_VER}"
else
  check_fail "helm: not found — install with: brew install helm"
fi

# curl
if command -v curl &>/dev/null; then
  CURL_VER=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
  check_pass "curl ${CURL_VER}"
else
  check_fail "curl: not found — install with: brew install curl"
fi

# jq
if command -v jq &>/dev/null; then
  JQ_VER=$(jq --version 2>/dev/null)
  check_pass "jq ${JQ_VER}"
else
  check_fail "jq: not found — install with: brew install jq"
fi

# cilium CLI (optional)
if command -v cilium &>/dev/null; then
  CILIUM_CLI_VER=$(cilium version --client 2>&1 | head -1)
  check_pass "cilium CLI: ${CILIUM_CLI_VER}"
else
  check_warn "cilium CLI: not installed (optional — install with: brew install cilium-cli)"
fi

##############################################################################
# Docker runtime checks
##############################################################################

section "Checking Docker Runtime"

if ! docker info &>/dev/null; then
  check_fail "Docker daemon is NOT running — start Docker Desktop and retry"
else
  check_pass "Docker daemon is running"

  # Memory check
  MEM_BYTES=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  MEM_GB=$(( MEM_BYTES / 1073741824 ))

  if [[ "${MEM_GB}" -ge 8 ]]; then
    check_pass "Docker memory: ${MEM_GB}GB (sufficient for all profiles)"
  elif [[ "${MEM_GB}" -ge 4 ]]; then
    check_warn "Docker memory: ${MEM_GB}GB — 8GB+ recommended for market-dev profile with full observability stack"
  else
    check_fail "Docker memory: ${MEM_GB}GB — minimum 4GB required, 8GB recommended. Increase in Docker Desktop → Settings → Resources"
  fi

  # CPU check
  NCPU=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  if [[ "${NCPU}" -ge 4 ]]; then
    check_pass "Docker CPUs: ${NCPU}"
  else
    check_warn "Docker CPUs: ${NCPU} — 4+ recommended for full stack"
  fi

  # Disk space
  DISK_FREE=$(df -g / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  if [[ "${DISK_FREE}" -ge 20 ]]; then
    check_pass "Disk free: ${DISK_FREE}GB"
  else
    check_warn "Disk free: ${DISK_FREE}GB — 20GB+ recommended for images and volumes"
  fi
fi

##############################################################################
# Helm repos
##############################################################################

section "Checking Helm Repositories"

helm_repos=(
  "cilium|https://helm.cilium.io/"
  "prometheus-community|https://prometheus-community.github.io/helm-charts"
  "grafana|https://grafana.github.io/helm-charts"
  "jetstack|https://charts.jetstack.io"
  "kyverno|https://kyverno.github.io/kyverno/"
  "external-secrets|https://charts.external-secrets.io"
  "ingress-nginx|https://kubernetes.github.io/ingress-nginx"
  "metallb|https://metallb.github.io/metallb"
  "open-telemetry|https://open-telemetry.github.io/opentelemetry-helm-charts"
  "istio|https://istio-release.storage.googleapis.com/charts"
)

for entry in "${helm_repos[@]}"; do
  repo_name="${entry%%|*}"
  repo_url="${entry##*|}"
  if helm repo list 2>/dev/null | grep -q "^${repo_name}[[:space:]]"; then
    check_pass "Helm repo '${repo_name}' configured"
  else
    log "Adding Helm repo: ${repo_name}"
    if helm repo add "${repo_name}" "${repo_url}" &>/dev/null; then
      check_pass "Helm repo '${repo_name}' added"
    else
      check_warn "Failed to add Helm repo '${repo_name}' — may need network access"
    fi
  fi
done

log "Updating Helm repos..."
helm repo update &>/dev/null && ok "Helm repos updated" || warn "Helm repo update had errors"

##############################################################################
# Summary
##############################################################################

section "Prerequisites Summary"

printf '\n' >&2
printf '  \033[0;32mPASS\033[0m: %d\n' "${PASS}" >&2
printf '  \033[0;33mWARN\033[0m: %d\n' "${WARN}" >&2
printf '  \033[0;31mFAIL\033[0m: %d\n' "${FAIL}" >&2
printf '\n' >&2

if [[ "${FAIL}" -gt 0 ]]; then
  die "Prerequisites check failed: ${FAIL} critical issue(s). Fix them before running install."
elif [[ "${WARN}" -gt 0 ]]; then
  warn "Prerequisites check passed with ${WARN} warning(s)."
  exit 0
else
  ok "All prerequisites satisfied!"
fi
