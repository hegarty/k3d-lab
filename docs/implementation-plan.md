# Implementation Plan

This document describes the phased approach to building the k3d-lab platform.

## Phase 1: Core Infrastructure (Day 1)

**Goal:** Working Kubernetes cluster with networking

### Steps

1. **Prerequisites check**
   ```bash
   bash bootstrap/prerequisites.sh
   ```
   - Verify Docker, k3d, kubectl, helm, curl, jq are installed
   - Verify Docker has enough memory (8GB+)
   - Add required Helm repos

2. **Create cluster**
   ```bash
   ./bootstrap/install.sh  # uses single-node profile by default
   ```
   - k3d creates cluster from `clusters/single-node.yaml`
   - k3s starts with Flannel and kube-proxy disabled
   - Nodes come up without a CNI

3. **Install Cilium**
   ```bash
   bash networking/cilium/install.sh
   ```
   - Detect server node Docker network IP
   - Helm install with kube-proxy replacement
   - Enable Hubble and Gateway API support

4. **Install Gateway API**
   ```bash
   bash networking/gateway-api/install.sh
   ```
   - Apply Gateway API standard CRDs (v1.1.0)
   - Wait for Cilium to register GatewayClass
   - Apply shared Gateway resource

5. **Deploy hello-world**
   ```bash
   bash workloads/hello-world/install.sh
   ```
   - traefik/whoami deployment
   - HTTPRoute attached to shared Gateway

6. **Validate**
   ```bash
   bash bootstrap/validate.sh
   ```
   - All nodes Ready
   - CoreDNS running
   - Cilium healthy
   - hello-world responding

**Estimated time:** 5-10 minutes

---

## Phase 2: Security (Day 1-2)

**Goal:** Policy enforcement and certificate management

### Steps

1. **cert-manager**
   ```bash
   bash security/cert-manager/install.sh
   ```
   - Install cert-manager with CRDs
   - Create self-signed ClusterIssuer
   - Bootstrap CA certificate
   - Create wildcard `*.localhost` certificate

2. **Kyverno**
   ```bash
   bash security/kyverno/install.sh
   ```
   - Install Kyverno
   - Apply policies in Audit mode:
     - disallow-latest-tag
     - disallow-privileged
     - require-resources
     - require-non-root

3. **External Secrets**
   ```bash
   bash security/external-secrets/install.sh
   ```
   - Install External Secrets Operator
   - Configure fake ClusterSecretStore
   - Verify ExternalSecret syncs

**Estimated time:** 10-15 minutes

---

## Phase 3: Observability (Day 2)

**Goal:** Full telemetry pipeline

### Steps

1. **kube-prometheus-stack**
   ```bash
   bash observability/kube-prometheus-stack/install.sh
   ```
   - Prometheus with 7d retention
   - Grafana with pre-configured datasources
   - AlertManager
   - kube-state-metrics + node-exporter

2. **Loki**
   ```bash
   bash observability/loki/install.sh
   ```
   - Loki in single-binary mode
   - Promtail DaemonSet for node logs

3. **Tempo**
   ```bash
   bash observability/tempo/install.sh
   ```
   - Tempo in monolithic mode
   - Accepts OTLP, Zipkin, Jaeger formats

4. **OpenTelemetry Collector**
   ```bash
   bash observability/opentelemetry/install.sh
   ```
   - DaemonSet + gateway aggregator
   - Pipelines: traces → Tempo, metrics → Prometheus, logs → Loki
   - k8s attribute enrichment

5. **Verify**
   ```bash
   bash tests/observability/run.sh
   ```

**Estimated time:** 15-20 minutes
**Memory requirement:** 8GB+ Docker Desktop

---

## Phase 4: Optional Components (As needed)

### MetalLB (if LoadBalancer IPs needed)
```bash
bash networking/metallb/install.sh
```

### Istio (if service mesh needed)
```bash
bash service-mesh/istio/install.sh
```

### NGINX Ingress (if needed alongside Gateway API)
```bash
bash ingress/nginx/install.sh
```

---

## Phase 5: Workloads and Testing

```bash
# Deploy test workloads
kubectl apply -f workloads/network-test/namespace.yaml
kubectl apply -f workloads/network-test/test-pods.yaml

# Run all tests
bash tests/smoke/run.sh
bash tests/networking/run.sh
bash tests/observability/run.sh
bash tests/security/run.sh
```

---

## Full Stack Install (All Phases)

```bash
cp .env.example .env
# Edit .env: set INSTALL_OBSERVABILITY=true INSTALL_SECURITY=true

./bootstrap/install.sh
```

Or use make:
```bash
make up                    # Phase 1
make security-install      # Phase 2
make observability-install # Phase 3
make test-all              # Verify
```

---

## Rollback / Reset

```bash
# Soft reset (recreate only)
bash bootstrap/reset.sh

# Uninstall specific component
helm uninstall cilium -n kube-system
helm uninstall kube-prometheus-stack -n observability

# Full destroy
bash bootstrap/uninstall.sh
```

---

## Resource Budget

| Profile | RAM (Docker) | CPU | Startup |
|---------|-------------|-----|---------|
| single-node (core only) | 2-3GB | 2 | 2 min |
| single-node + security | 3-4GB | 2 | 5 min |
| single-node + observability | 5-6GB | 3 | 10 min |
| single-node + full stack | 6-8GB | 4 | 15 min |
| ha + full stack | 10-12GB | 6 | 20 min |
| market-dev + full stack | 12-16GB | 6-8 | 20 min |
