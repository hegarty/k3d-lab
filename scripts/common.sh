#!/usr/bin/env bash
# common.sh — shared utilities for k3d-lab scripts
set -Eeuo pipefail

# Resolve repository root (directory containing this scripts/ directory)
# Guard against re-declaration when common.sh is sourced from another script
# that already set REPO_ROOT.
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
readonly REPO_ROOT

# Load versions first, then .env (which can override)
load_env() {
  if [[ -f "${REPO_ROOT}/versions.env" ]]; then
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/versions.env"
  fi
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    # shellcheck source=/dev/null
    set -o allexport
    source "${REPO_ROOT}/.env"
    set +o allexport
  fi
}

# Logging
log()  { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[ERR ]\033[0m  %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Section header
section() {
  printf '\n\033[1;36m══════════════════════════════════════════\033[0m\n' >&2
  printf '\033[1;36m  %s\033[0m\n' "$*" >&2
  printf '\033[1;36m══════════════════════════════════════════\033[0m\n\n' >&2
}

# Check required commands
require_commands() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "${cmd}" &>/dev/null; then
      err "Required command not found: ${cmd}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || die "Install missing commands and retry."
}

# Check required env vars
require_env() {
  local missing=0
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      err "Required environment variable not set: ${var}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || die "Set missing environment variables and retry."
}

# k3d cluster exists?
cluster_exists() {
  local name="${1}"
  k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${name}\""
}

# kubectl context for cluster
cluster_context() {
  local name="${1}"
  echo "k3d-${name}"
}

# Helm repo add-or-update
helm_repo_add() {
  local name="${1}" url="${2}"
  if helm repo list 2>/dev/null | grep -q "^${name}[[:space:]]"; then
    helm repo update "${name}" >/dev/null
  else
    helm repo add "${name}" "${url}"
    helm repo update "${name}" >/dev/null
  fi
  ok "Helm repo '${name}' ready"
}

# Namespace idempotent create
ensure_namespace() {
  local ns="${1}"
  kubectl get namespace "${ns}" &>/dev/null || \
    kubectl create namespace "${ns}"
}

# Trap helper — print context on ERR
trap_err() {
  local lineno="${1}" cmd="${2:-unknown}"
  err "Command failed at line ${lineno}: ${cmd}"
}
