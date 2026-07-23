#!/usr/bin/env bash
# install.sh — install NGINX Ingress Controller
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
load_env

# shellcheck source=scripts/wait-for.sh
source "${REPO_ROOT}/scripts/wait-for.sh"

NGINX_CHART_VERSION="${NGINX_CHART_VERSION:-4.10.1}"

section "Installing NGINX Ingress Controller v${NGINX_CHART_VERSION}"

helm_repo_add ingress-nginx https://kubernetes.github.io/ingress-nginx

ensure_namespace ingress-nginx

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "${NGINX_CHART_VERSION}" \
  --namespace ingress-nginx \
  --values "${REPO_ROOT}/ingress/nginx/values.yaml" \
  --timeout 3m \
  --wait

ok "NGINX Ingress Controller installed"
wait_for_rollout ingress-nginx daemonset/ingress-nginx-controller 180

kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx

ok "NGINX Ingress ready"
log "IngressClass: nginx"
log "Use 'ingressClassName: nginx' in Ingress resources to route via NGINX"
