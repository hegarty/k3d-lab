#!/usr/bin/env bash
# doctor.sh — environment health check and diagnostic report
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

PASS=0
FAIL=0
WARN=0

check_pass() { ok "$1"; (( PASS++ )) || true; }
check_fail() { err "$1"; (( FAIL++ )) || true; }
check_warn() { warn "$1"; (( WARN++ )) || true; }

section "k3d-lab Doctor"

##############################################################################
# Tool versions
##############################################################################
section "Required Tools"

check_tool() {
  local tool="${1}" version_flag="${2:---version}"
  if command -v "${tool}" &>/dev/null; then
    local ver
    ver=$(${tool} ${version_flag} 2>&1 | head -1)
    check_pass "${tool}: ${ver}"
  else
    check_fail "${tool}: NOT FOUND"
  fi
}

check_tool docker "version --format '{{.Client.Version}}'"
check_tool k3d version
check_tool kubectl version --client=true --output=yaml
check_tool helm version --short
check_tool curl --version
check_tool jq --version

if command -v cilium &>/dev/null; then
  check_pass "cilium CLI: $(cilium version --client 2>&1 | head -1)"
else
  check_warn "cilium CLI: not installed (optional — needed for connectivity tests)"
fi

if command -v task &>/dev/null; then
  check_pass "task: $(task --version 2>&1 | head -1)"
else
  check_warn "task (go-task): not installed (optional — Taskfile.yml requires it)"
fi

##############################################################################
# Docker
##############################################################################
section "Docker"

if docker info &>/dev/null; then
  check_pass "Docker daemon is running"

  # Memory check
  local_mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  local_mem_gb=$(( local_mem_bytes / 1073741824 ))
  if [[ "${local_mem_gb}" -ge 8 ]]; then
    check_pass "Docker memory: ${local_mem_gb}GB (>= 8GB recommended)"
  elif [[ "${local_mem_gb}" -ge 4 ]]; then
    check_warn "Docker memory: ${local_mem_gb}GB (8GB recommended for full stack)"
  else
    check_fail "Docker memory: ${local_mem_gb}GB (4GB minimum, 8GB recommended)"
  fi

  # CPU check
  local_cpus=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  if [[ "${local_cpus}" -ge 4 ]]; then
    check_pass "Docker CPUs: ${local_cpus} (>= 4 recommended)"
  else
    check_warn "Docker CPUs: ${local_cpus} (4+ recommended for full stack)"
  fi
else
  check_fail "Docker daemon is NOT running — start Docker Desktop"
fi

##############################################################################
# k3d clusters
##############################################################################
section "k3d Clusters"

if k3d cluster list &>/dev/null; then
  cluster_count=$(k3d cluster list -o json 2>/dev/null | jq length 2>/dev/null || echo 0)
  if [[ "${cluster_count}" -gt 0 ]]; then
    check_pass "${cluster_count} k3d cluster(s) found:"
    k3d cluster list >&2
  else
    check_warn "No k3d clusters running"
  fi
else
  check_warn "Cannot list k3d clusters"
fi

##############################################################################
# Helm repos
##############################################################################
section "Helm Repositories"

required_repos=(
  "cilium:https://helm.cilium.io/"
  "prometheus-community:https://prometheus-community.github.io/helm-charts"
  "grafana:https://grafana.github.io/helm-charts"
  "jetstack:https://charts.jetstack.io"
  "kyverno:https://kyverno.github.io/kyverno/"
  "external-secrets:https://charts.external-secrets.io"
)

for entry in "${required_repos[@]}"; do
  repo_name="${entry%%:*}"
  if helm repo list 2>/dev/null | grep -q "^${repo_name}[[:space:]]"; then
    check_pass "Helm repo: ${repo_name}"
  else
    check_warn "Helm repo not added: ${repo_name} (run: make up to add automatically)"
  fi
done

##############################################################################
# Environment files
##############################################################################
section "Environment Files"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  check_pass ".env file exists"
else
  check_warn ".env file not found — copy .env.example to .env and configure"
fi

if [[ -f "${REPO_ROOT}/versions.env" ]]; then
  check_pass "versions.env file exists"
else
  check_fail "versions.env file missing"
fi

##############################################################################
# Summary
##############################################################################
section "Summary"

total=$(( PASS + FAIL + WARN ))
printf '\n' >&2
printf '  \033[0;32mPASS\033[0m: %d\n' "${PASS}" >&2
printf '  \033[0;33mWARN\033[0m: %d\n' "${WARN}" >&2
printf '  \033[0;31mFAIL\033[0m: %d\n' "${FAIL}" >&2
printf '  Total: %d checks\n\n' "${total}" >&2

if [[ "${FAIL}" -gt 0 ]]; then
  die "Doctor found ${FAIL} critical issue(s). Fix them before proceeding."
elif [[ "${WARN}" -gt 0 ]]; then
  warn "Doctor found ${WARN} warning(s). Review before running full stack."
  exit 0
else
  ok "All checks passed!"
fi
