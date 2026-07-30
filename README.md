# k3d-lab

A reusable local Kubernetes platform built on k3d/k3s with Cilium CNI, Gateway API, full observability, and security tooling. Designed to mirror production EKS patterns for local development and testing.

> **Tested environment:** macOS (Apple Silicon), Docker Desktop 28.1.1, k3d v5.8.3, kubectl v1.32.2, Helm v3.18.5

---

## Stack

| Component | Version | Purpose |
|---|---|---|
| k3d | v5.8.3 | Local Kubernetes cluster manager |
| k3s | v1.30.2-k3s2 | Lightweight Kubernetes distribution |
| Cilium | v1.15.6 | CNI + kube-proxy replacement + Gateway API controller |
| Gateway API CRDs | v1.1.0 (experimental channel) | Next-gen ingress/routing |
| CiliumLoadBalancerIPPool | built-in | LoadBalancer IP assignment (replaces MetalLB) |
| Istio | v1.22.2 | Service mesh (optional) |
| kube-prometheus-stack | v61.3.2 | Prometheus + Grafana |
| Loki | v6.6.4 | Log aggregation |
| Tempo | v1.10.3 | Distributed tracing |
| OpenTelemetry Collector | v0.102.1 | Telemetry pipeline |
| cert-manager | v1.15.1 | Certificate management |
| Kyverno | v3.2.6 | Policy engine |
| External Secrets Operator | v0.10.0 | Secret management |

---

## Prerequisites

| Tool | Minimum | Install |
|---|---|---|
| Docker Desktop | 28.x, 8 GB RAM | [docs.docker.com](https://docs.docker.com/desktop/install/mac-install/) |
| k3d | v5.7+ | `brew install k3d` |
| kubectl | v1.30+ | `brew install kubectl` |
| Helm | v3.15+ | `brew install helm` |
| jq | any | `brew install jq` |
| cilium CLI | any | `brew install cilium-cli` (optional) |

Check all prerequisites:

```bash
make prerequisites
```

---

## Quick Start — Minimal Cluster

```bash
# 1. Clone and configure
git clone <repo-url> k3d-lab && cd k3d-lab
cp .env.example .env

# 2. Check prerequisites (installs Helm repos too)
make prerequisites

# 3. Bootstrap — creates cluster, installs Cilium + Gateway API + hello-world
make bootstrap-minimal PROFILE=single-node

# 4. Run smoke tests
make test-smoke

# 5. Run networking tests
make test-networking
```

Expected outcome: **19/19 tests pass**.

---

## Daily Operations

### Start / stop the cluster

k3d clusters run as Docker containers. They persist across Docker Desktop restarts **as long as Docker Desktop is running**.

```bash
# Start Docker Desktop first, then check cluster status
kubectl get nodes

# If the cluster was deleted, recreate it:
make bootstrap-minimal PROFILE=single-node
```

> k3d does not have a native "pause" — the cluster is always running when Docker is running.
> To free resources, delete the cluster and recreate it when needed.

### Delete the cluster

```bash
make cluster-delete CLUSTER_NAME=k3d-lab
```

This removes the k3d cluster containers, the Docker network, and the kubeconfig context. It does **not** prune Docker images or volumes.

### Recreate from scratch

```bash
make cluster-delete CLUSTER_NAME=k3d-lab
make bootstrap-minimal PROFILE=single-node
```

Or use the reset target (delete + recreate in one step):

```bash
make cluster-reset PROFILE=single-node
```

### Check what is running

```bash
make status          # nodes, pods, services, access URLs
make doctor          # diagnose common problems
kubectl get pods -A  # all pods across all namespaces
```

---

## Cluster Profiles

| Profile | Servers | Agents | Host Ports | Registry | Default Stack |
|---|---|---|---|---|---|
| `single-node` | 1 | 0 | 8080, 8443, 9090 | No | Cilium, Gateway API, hello-world |
| `ha` | 3 | 2 | 8180, 8543 | No | Cilium, Gateway API |
| `market-dev` | 1 | 2 | 8280, 8643, 3000, 16686 | Yes (port 5000) | Full platform stack |

```bash
# Create a specific profile
make bootstrap-minimal PROFILE=single-node
make bootstrap-market  PROFILE=market-dev

# Delete a specific cluster by name
make cluster-delete CLUSTER_NAME=k3d-lab
make cluster-delete CLUSTER_NAME=market-dev
```

---

## Port Mappings

### single-node (cluster name: k3d-lab)

| Mac port | Cluster port | Use |
|---|---|---|
| 8080 | 80 | HTTP (k3d LB → node) |
| 8443 | 443 | HTTPS |
| 9090 | 9090 | Prometheus direct |

### market-dev (cluster name: market-dev)

| Mac port | Cluster port | Use |
|---|---|---|
| 8280 | 80 | HTTP |
| 8643 | 443 | HTTPS |
| 3000 | 3000 | Grafana |
| 16686 | 16686 | Jaeger / Tempo UI |
| 5000 | — | Local container registry |

> **Note:** On macOS with Docker Desktop, the Docker network (`172.21.x.x`) is not routable from the host.
> Use `kubectl port-forward` or the mapped host ports above to reach services.

---

## Accessing Services

```bash
# hello-world — direct port-forward
kubectl port-forward -n hello-world svc/hello-world 8888:8080
curl http://localhost:8888/health

# hello-world — via Gateway (requires LB IP, only reachable inside cluster)
# from inside cluster: curl -H 'Host: hello-world.localhost' http://172.21.100.1/

# Hubble UI (Cilium network flows)
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# open http://localhost:12000

# Grafana (after observability-install)
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# open http://localhost:3000  —  admin / prom-operator

# Prometheus (after observability-install)
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090
```

Or use the Makefile shortcuts:

```bash
make hubble-ui    # port-forwards Hubble UI to localhost:12000
make grafana      # port-forwards Grafana to localhost:3000
make prometheus   # port-forwards Prometheus to localhost:9090
```

---

## Component Management

```bash
# Cilium
make cilium-install
make cilium-uninstall
make cilium-status
make cilium-test          # full connectivity test (~5-10 min, resource-heavy)

# Gateway API
make gateway-api-install

# Observability (Prometheus + Grafana + Loki + Tempo + OTel)
make observability-install
make observability-uninstall

# Security (cert-manager + Kyverno + External Secrets)
make security-install
make security-uninstall

# Istio (optional service mesh)
make istio-install
make istio-uninstall

# Storage
make storage-install
make storage-test

# Workloads
make workloads-install
make workloads-uninstall
```

---

## Testing

```bash
make test-smoke         # 10 tests: nodes, DNS, Cilium, hello-world, CRDs, PVC
make test-networking    # 9 tests: DNS, intra/cross-namespace, network policy, Hubble
make test-observability # Prometheus, Grafana, Loki, Tempo, OTel readiness
make test-security      # cert-manager, Kyverno, External Secrets
make test-all           # all of the above
```

---

## Known Operational Notes (k3d + macOS)

These were discovered during the first runtime session and are already fixed in the repo.

### Cilium node-init is disabled

k3d node containers have no `bash`. The `nodeinit` component runs `nsenter` to execute a bash script on the host — this crashes on k3d.
**Fix applied:** `nodeinit.enabled: false` in `networking/cilium/values.yaml`.

### Cilium cluster identity

Cilium 1.15 rejects `cluster.id: 1` when `cluster.name: "default"`.
**Fix applied:** `cluster.name: "k3d-lab", cluster.id: 0`.

### Gateway API requires the experimental CRD channel

Cilium 1.15's Gateway API controller requires `TLSRoute` CRD which is only in the experimental channel. The standard channel (`standard-install.yaml`) is missing it and the controller refuses to start.
**Fix applied:** `networking/gateway-api/install.sh` now applies `experimental-install.yaml`.

### MetalLB conflicts with Cilium kube-proxy replacement

The MetalLB speaker uses `hostNetwork: true` and tries to reach the Kubernetes API via ClusterIP (`10.43.0.1`). Cilium's eBPF socket-level load balancing does not apply to host-network pods in k3d's nested cgroup environment, so the connection times out.
**Fix applied:** MetalLB is not used. Use `CiliumLoadBalancerIPPool` instead (see `make metallb-install` comments).

### LoadBalancer IP is not reachable from macOS

Even with `CiliumLoadBalancerIPPool` assigning `172.21.100.1` to the Gateway, this IP is inside the Docker network VM and is not routable from macOS.
**Workaround:** Use `kubectl port-forward` to access any service. The Gateway path works correctly from inside the cluster.

### Gateway API Envoy upstream connectivity (503)

The Cilium embedded Envoy processes HTTP through the Gateway and applies HTTPRoute filters correctly (confirmed by response headers), but returns 503 when connecting to backend pods. This is a known k3d limitation where Cilium's eBPF socket-level LB does not apply to the Envoy process in the agent container's cgroup.
**Status:** Known limitation on k3d/macOS. Direct service access via port-forward works fully.

---

## Directory Structure

```
k3d-lab/
├── bootstrap/          # Cluster lifecycle scripts
├── clusters/           # k3d cluster config YAMLs (single-node, ha, market-dev)
├── networking/
│   ├── cilium/         # Cilium Helm values + install scripts + network policies
│   ├── metallb/        # MetalLB (not recommended on k3d — use CiliumLoadBalancerIPPool)
│   └── gateway-api/    # Gateway API CRDs + Gateway + HTTPRoutes
├── service-mesh/
│   └── istio/          # Istio (optional)
├── observability/
│   ├── kube-prometheus-stack/
│   ├── loki/
│   ├── tempo/
│   └── opentelemetry/
├── ingress/
│   ├── nginx/
│   └── istio/
├── storage/
│   └── local-path/
├── security/
│   ├── cert-manager/
│   ├── kyverno/
│   └── external-secrets/
├── workloads/
│   ├── hello-world/    # Validation workload (traefik/whoami:v1.10.3)
│   ├── network-test/   # Network policy test pods
│   └── otel-demo/      # OpenTelemetry demo app
├── tests/
│   ├── smoke/          # 10 smoke tests
│   ├── networking/     # 9 networking tests
│   ├── observability/  # Observability readiness tests
│   └── security/       # Policy tests
├── scripts/            # Shared shell library (common.sh, wait-for.sh, etc.)
├── docs/               # Architecture, troubleshooting, migration docs
├── versions.env        # All pinned versions
├── .env.example        # Configuration template
├── Makefile            # Primary interface — run `make help`
└── Taskfile.yml        # Task alternative interface
```

---

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for full diagnostics.

Quick checks:

```bash
make doctor                                    # automated diagnostics
kubectl get pods -A                            # all pod status
kubectl logs -n kube-system -l k8s-app=cilium --tail=50  # Cilium agent logs
kubectl get gateway -A                         # Gateway status
kubectl get httproute -A                       # HTTPRoute status
```

---

## Migration to EKS

See [docs/migration-to-eks.md](docs/migration-to-eks.md) for a component-by-component mapping of what changes when moving to AWS EKS.
