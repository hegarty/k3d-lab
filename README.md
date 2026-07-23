# k3d-lab

A reusable local Kubernetes platform built on k3d/k3s with Cilium CNI, Gateway API, full observability, and security tooling. Designed to mirror production EKS patterns for local development and testing.

## Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| k3d | v5.7.x | Local Kubernetes cluster manager |
| k3s | v1.30.2-k3s2 | Lightweight Kubernetes |
| Cilium | v1.15.6 | CNI + kube-proxy replacement + Gateway API |
| Gateway API | v1.1.0 | Next-gen ingress/routing |
| MetalLB | v0.14.5 | LoadBalancer (optional) |
| Istio | v1.22.2 | Service mesh (optional) |
| kube-prometheus-stack | v61.3.2 | Prometheus + Grafana |
| Loki | v6.6.4 | Log aggregation |
| Tempo | v1.10.3 | Distributed tracing |
| OpenTelemetry Collector | v0.102.1 | Telemetry pipeline |
| cert-manager | v1.15.1 | Certificate management |
| Kyverno | v3.2.6 | Policy engine |
| External Secrets | v0.10.0 | Secret management |

## Prerequisites

- Docker Desktop (8GB+ RAM recommended)
- k3d v5.7+
- kubectl v1.30+
- helm v3.15+
- cilium CLI (optional, for connectivity tests)
- curl, jq

Install prerequisites check:

```bash
./bootstrap/prerequisites.sh
```

## Quick Start

```bash
# 1. Copy and edit environment
cp .env.example .env
# Edit .env as needed

# 2. Install everything (single-node profile)
./bootstrap/install.sh

# 3. Validate the cluster
./bootstrap/validate.sh

# 4. Check cluster info
./scripts/cluster-info.sh
```

Or use Make:

```bash
make up              # create cluster + core stack
make status          # cluster info
make validate        # run validation
make down            # destroy cluster
make reset           # destroy + recreate
```

Or use Task:

```bash
task up
task status
task validate
task down
```

## Cluster Profiles

| Profile | File | Servers | Agents | Use Case |
|---------|------|---------|--------|----------|
| `single-node` | `clusters/single-node.yaml` | 1 | 0 | Fast dev, CI |
| `ha` | `clusters/ha.yaml` | 3 | 2 | HA testing |
| `market-dev` | `clusters/market-dev.yaml` | 1 | 2 | Full stack + registry |

```bash
CLUSTER_PROFILE=ha ./bootstrap/install.sh
CLUSTER_PROFILE=market-dev ./bootstrap/install.sh
```

## Port Mappings

### single-node
| Host Port | Cluster Port | Service |
|-----------|-------------|---------|
| 8080 | 80 | HTTP ingress |
| 8443 | 443 | HTTPS ingress |
| 9090 | 9090 | Prometheus (direct) |

### ha
| Host Port | Cluster Port | Service |
|-----------|-------------|---------|
| 8180 | 80 | HTTP ingress (via LB) |
| 8543 | 443 | HTTPS ingress (via LB) |

### market-dev
| Host Port | Cluster Port | Service |
|-----------|-------------|---------|
| 8280 | 80 | HTTP ingress |
| 8643 | 443 | HTTPS ingress |
| 16686 | 16686 | Jaeger UI |
| 3000 | 3000 | Grafana |
| 5000 | - | Local registry |

## Directory Structure

```
k3d-lab/
├── bootstrap/          # Install/uninstall/validate scripts
├── clusters/           # k3d cluster config YAMLs
├── networking/
│   ├── cilium/         # Cilium CNI + network policies
│   ├── metallb/        # MetalLB LoadBalancer (optional)
│   └── gateway-api/    # Gateway API CRDs + resources
├── service-mesh/
│   └── istio/          # Istio service mesh (optional)
├── observability/
│   ├── kube-prometheus-stack/
│   ├── loki/
│   ├── tempo/
│   └── opentelemetry/
├── ingress/
│   ├── nginx/          # NGINX ingress controller (optional)
│   └── istio/          # Istio ingress resources
├── storage/
│   └── local-path/     # Local path provisioner resources
├── security/
│   ├── cert-manager/   # Certificate management
│   ├── kyverno/        # Policy engine + policies
│   └── external-secrets/ # External secret management
├── workloads/
│   ├── hello-world/    # Simple test workload
│   ├── network-test/   # Network connectivity tests
│   └── otel-demo/      # OpenTelemetry demo app
├── tests/
│   ├── smoke/          # Smoke tests
│   ├── networking/     # Network tests
│   ├── observability/  # Observability tests
│   └── security/       # Security policy tests
├── scripts/            # Shared utilities
├── docs/               # Documentation
├── versions.env        # Pinned component versions
├── .env.example        # Environment template
└── Makefile / Taskfile.yml
```

## Accessing Services

After install, access services via port-forward or the mapped ports:

```bash
# Grafana (kube-prometheus-stack)
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000 (admin/prom-operator)

# Hubble UI (Cilium)
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# Open http://localhost:12000

# Prometheus
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090

# hello-world via host port
curl http://localhost:8080
```

## Running Tests

```bash
./tests/smoke/run.sh          # Basic connectivity
./tests/networking/run.sh     # Network policy tests
./tests/observability/run.sh  # Metrics/logs/traces
./tests/security/run.sh       # Kyverno policy tests
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Migration to EKS

See [docs/migration-to-eks.md](docs/migration-to-eks.md) for mapping local components to AWS equivalents.
