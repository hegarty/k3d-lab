.PHONY: help up down reset status validate \
        cilium-install gateway-api-install \
        observability-install security-install \
        hello-world-install \
        test-smoke test-networking test-observability test-security \
        doctor prerequisites

SHELL := /usr/bin/env bash
REPO_ROOT := $(shell pwd)

# Load versions and .env if present
-include versions.env
-include .env

CLUSTER_PROFILE ?= single-node
CLUSTER_NAME    ?= k3d-lab

##@ General

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster Lifecycle

up: prerequisites ## Create cluster and install core stack
	@CLUSTER_PROFILE=$(CLUSTER_PROFILE) CLUSTER_NAME=$(CLUSTER_NAME) bash bootstrap/install.sh

down: ## Destroy the cluster
	@bash bootstrap/uninstall.sh

reset: ## Destroy and recreate the cluster
	@bash bootstrap/reset.sh

prerequisites: ## Check prerequisites
	@bash bootstrap/prerequisites.sh

##@ Validation & Status

validate: ## Run cluster validation
	@bash bootstrap/validate.sh

status: ## Show cluster info
	@bash scripts/cluster-info.sh

doctor: ## Run environment doctor checks
	@bash scripts/doctor.sh

##@ Networking

cilium-install: ## Install Cilium CNI
	@bash networking/cilium/install.sh

cilium-uninstall: ## Uninstall Cilium
	@bash networking/cilium/uninstall.sh

gateway-api-install: ## Install Gateway API CRDs and resources
	@bash networking/gateway-api/install.sh

metallb-install: ## Install MetalLB (optional)
	@bash networking/metallb/install.sh

##@ Observability

observability-install: ## Install full observability stack
	@bash observability/kube-prometheus-stack/install.sh
	@bash observability/loki/install.sh
	@bash observability/tempo/install.sh
	@bash observability/opentelemetry/install.sh

prometheus-install: ## Install kube-prometheus-stack only
	@bash observability/kube-prometheus-stack/install.sh

loki-install: ## Install Loki
	@bash observability/loki/install.sh

tempo-install: ## Install Tempo
	@bash observability/tempo/install.sh

otel-install: ## Install OpenTelemetry Collector
	@bash observability/opentelemetry/install.sh

##@ Security

security-install: ## Install security stack (cert-manager, kyverno, external-secrets)
	@bash security/cert-manager/install.sh
	@bash security/kyverno/install.sh
	@bash security/external-secrets/install.sh

cert-manager-install: ## Install cert-manager
	@bash security/cert-manager/install.sh

kyverno-install: ## Install Kyverno
	@bash security/kyverno/install.sh

external-secrets-install: ## Install External Secrets Operator
	@bash security/external-secrets/install.sh

##@ Service Mesh

istio-install: ## Install Istio (optional)
	@bash service-mesh/istio/install.sh

istio-uninstall: ## Uninstall Istio
	@bash service-mesh/istio/uninstall.sh

##@ Ingress

nginx-install: ## Install NGINX ingress controller (optional)
	@bash ingress/nginx/install.sh

##@ Workloads

hello-world: ## Deploy hello-world workload
	@bash workloads/hello-world/install.sh

otel-demo: ## Deploy OpenTelemetry demo app
	@kubectl apply -f workloads/otel-demo/namespace.yaml
	@kubectl apply -f workloads/otel-demo/otel-demo.yaml

##@ Tests

test-smoke: ## Run smoke tests
	@bash tests/smoke/run.sh

test-networking: ## Run networking tests
	@bash tests/networking/run.sh

test-observability: ## Run observability tests
	@bash tests/observability/run.sh

test-security: ## Run security tests
	@bash tests/security/run.sh

test-all: test-smoke test-networking test-observability test-security ## Run all tests

##@ Utilities

chmod-scripts: ## Make all scripts executable
	@find . -name "*.sh" -exec chmod +x {} \;
	@echo "All scripts are now executable"

lint-scripts: ## Bash syntax check all scripts
	@find . -name "*.sh" | while read f; do \
		bash -n "$$f" && echo "OK: $$f" || echo "FAIL: $$f"; \
	done

hubble-ui: ## Port-forward Hubble UI to localhost:12000
	@kubectl port-forward -n kube-system svc/hubble-ui 12000:80

grafana: ## Port-forward Grafana to localhost:3000
	@kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80

prometheus: ## Port-forward Prometheus to localhost:9090
	@kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
