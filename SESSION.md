# k3d-lab — Session Notes

> **What is this file?**
> This document captures everything built in the Claude Code CLI session that created this repository.
> It is written so you can read it on your phone (GitHub iOS app) and pick up exactly where we left off.

---

## Table of Contents

1. [What we built and why](#1-what-we-built-and-why)
2. [Current status](#2-current-status)
3. [Repository structure — every file explained](#3-repository-structure--every-file-explained)
4. [Architecture decisions](#4-architecture-decisions)
5. [Component versions](#5-component-versions)
6. [Cluster profiles](#6-cluster-profiles)
7. [How the bootstrap sequence works](#7-how-the-bootstrap-sequence-works)
8. [Networking deep dive](#8-networking-deep-dive)
9. [Observability stack](#9-observability-stack)
10. [Security tooling](#10-security-tooling)
11. [Testing strategy](#11-testing-strategy)
12. [Key commands — cheat sheet](#12-key-commands--cheat-sheet)
13. [What has NOT been tested yet](#13-what-has-not-been-tested-yet)
14. [Recommended next steps when back at your laptop](#14-recommended-next-steps-when-back-at-your-laptop)
15. [Known risks and gotchas](#15-known-risks-and-gotchas)

---

## 1. What we built and why

### The goal

You wanted a **reusable local Kubernetes platform** that you can spin up on your Mac with Docker Desktop. The platform should:

- Feel like a real production cluster (real CNI, real service mesh, real observability)
- Be fast to create and destroy
- Use the same Kubernetes patterns (Helm charts, manifests, Gateway API) as a real AWS EKS cluster
- Let you experiment with Cilium, Istio, Prometheus, Grafana, Loki, Tempo, cert-manager, and Kyverno locally before deploying to EKS

### What was created

A fully functional repository at `~/projects/hegarty/k3d-lab` with **91 files** across the complete structure. Every shell script has real working content (not placeholders), all 28 scripts pass `bash -n` syntax validation, and all YAML manifests use pinned image and chart versions.

### The two main workflows

**Minimal bootstrap** — fast cluster for networking and Kubernetes experimentation:
```bash
make bootstrap-minimal PROFILE=single-node
```

**Market dev bootstrap** — full platform with observability, security, and service mesh:
```bash
make bootstrap-market PROFILE=market-dev
```

---

## 2. Current status

| Item | Status |
|---|---|
| All files created | ✅ Done |
| Shell script syntax (`bash -n`) | ✅ All 28 scripts pass |
| YAML structure | ✅ Complete |
| Runtime test (actual cluster creation) | ❌ Not yet run — needs Docker Desktop + k3d |
| `make prerequisites` | ❌ Not yet run |
| `make bootstrap-minimal` | ❌ Not yet run |
| `make test-smoke` | ❌ Not yet run |

> **The first thing to do when you get back to your laptop is run `make prerequisites` and then `make bootstrap-minimal PROFILE=single-node`.**
> The most likely failure point on first run is the Cilium API server IP detection (explained in section 8).

---

## 3. Repository structure — every file explained

```
k3d-lab/
├── .env.example          ← Copy to .env and edit. Controls all optional components.
├── .gitignore            ← Excludes .env, *.log, .DS_Store, kubeconfig files, etc.
├── versions.env          ← Single source of truth for ALL pinned versions.
├── README.md             ← Full project README with quick-start guide.
├── Makefile              ← Primary user interface. Run `make help` to see all targets.
├── Taskfile.yml          ← Alternative interface using Task (mirrors the Makefile).
│
├── clusters/
│   ├── single-node.yaml  ← k3d cluster config: 1 server, 0 agents, ports 8080/8443/9090
│   ├── ha.yaml           ← k3d cluster config: 3 servers, 2 agents (HA testing)
│   └── market-dev.yaml   ← k3d cluster config: 1 server, 2 agents + local registry
│
├── scripts/
│   ├── common.sh         ← Shared library sourced by ALL other scripts. Has logging,
│   │                        repo root detection, helm_repo_add, ensure_namespace, etc.
│   ├── wait-for.sh       ← Readiness helpers: wait_for_rollout, wait_for_pods_ready,
│   │                        wait_for_crd, wait_for_helm_release, wait_for_url
│   ├── cluster-info.sh   ← Prints a dashboard: nodes, pods, services, access URLs
│   └── doctor.sh         ← Diagnoses common problems (Docker down, Cilium unhealthy, etc.)
│
├── bootstrap/
│   ├── prerequisites.sh  ← Checks all required tools are installed and Docker is running
│   ├── install.sh        ← MAIN ORCHESTRATOR. Runs the full bootstrap sequence.
│   ├── uninstall.sh      ← Removes all components, then deletes the k3d cluster
│   ├── reset.sh          ← Deletes cluster then recreates it with the same profile
│   └── validate.sh       ← Checks nodes, system pods, Cilium, CoreDNS, hello-world
│
├── networking/
│   ├── cilium/
│   │   ├── values.yaml            ← Cilium Helm values (vxlan tunnel, kube-proxy
│   │   │                             replacement, Hubble enabled, Prometheus metrics)
│   │   ├── install.sh             ← Detects API server IP, runs helm upgrade --install
│   │   ├── uninstall.sh           ← helm uninstall cilium
│   │   └── policies/
│   │       ├── default-deny.yaml          ← Deny all ingress/egress by default
│   │       ├── allow-dns.yaml             ← Allow DNS to kube-system (required for any workload)
│   │       └── namespace-to-namespace.yaml ← Example cross-namespace allow rule
│   │
│   ├── metallb/
│   │   ├── values.yaml            ← MetalLB Helm values
│   │   ├── install.sh             ← Optional. Only for Layer 2 LoadBalancer testing.
│   │   └── manifests/
│   │       ├── address-pool.yaml  ← IPAddressPool (IP range from Docker network)
│   │       └── l2-advertisement.yaml ← L2Advertisement resource
│   │
│   └── gateway-api/
│       ├── install.sh             ← Applies Gateway API CRDs, waits, applies gateway
│       ├── gateway-class.yaml     ← REFERENCE ONLY — Cilium creates its own GatewayClass
│       ├── gateway.yaml           ← Gateway resource (gatewayClassName: cilium, port 80)
│       └── routes/
│           └── hello-world-route.yaml ← HTTPRoute pointing to hello-world service
│
├── service-mesh/
│   └── istio/
│       ├── values.yaml            ← Istio Helm values (sidecar mode)
│       ├── install.sh             ← Installs istiod + optionally ingress gateway
│       ├── uninstall.sh           ← istioctl uninstall --purge
│       └── manifests/
│           ├── peer-authentication.yaml ← STRICT mTLS for the mesh namespace
│           └── gateway.yaml            ← Istio Gateway resource (when Istio is ingress)
│
├── observability/
│   ├── kube-prometheus-stack/
│   │   ├── values.yaml  ← Prometheus + Grafana values. Grafana datasources for
│   │   │                   Loki and Tempo are pre-configured here.
│   │   └── install.sh
│   ├── loki/
│   │   ├── values.yaml  ← singleBinary mode (not distributed — saves RAM locally)
│   │   └── install.sh
│   ├── tempo/
│   │   ├── values.yaml  ← Single binary, OTLP gRPC + HTTP ingest
│   │   └── install.sh
│   └── opentelemetry/
│       ├── values.yaml
│       ├── install.sh
│       └── collectors/
│           └── collector.yaml  ← OTel Collector: OTLP receiver → Tempo + Prometheus + Loki
│
├── ingress/
│   ├── nginx/
│   │   ├── values.yaml   ← NGINX Ingress Controller Helm values
│   │   └── install.sh
│   └── istio/
│       ├── gateway.yaml            ← Istio Gateway for ingress traffic
│       └── routes/
│           └── hello-world-vs.yaml ← VirtualService for hello-world
│
├── storage/
│   └── local-path/
│       ├── storage-class.yaml ← Explicit StorageClass using k3s local-path provisioner
│       ├── test-pvc.yaml      ← PersistentVolumeClaim for testing
│       └── test-pod.yaml      ← Pod that writes to PVC to validate persistence
│
├── security/
│   ├── cert-manager/
│   │   ├── values.yaml
│   │   ├── install.sh
│   │   └── issuers/
│   │       ├── selfsigned-issuer.yaml  ← SelfSigned ClusterIssuer (no DNS needed)
│   │       ├── ca-issuer.yaml          ← CA-backed ClusterIssuer using local cert
│   │       └── test-certificate.yaml   ← Test Certificate resource to verify issuer works
│   │
│   ├── kyverno/
│   │   ├── values.yaml    ← Deployed in Audit mode (won't block workloads)
│   │   ├── install.sh
│   │   └── policies/
│   │       ├── disallow-privileged.yaml  ← Block privileged containers
│   │       ├── require-resources.yaml    ← Require CPU/memory requests and limits
│   │       ├── require-non-root.yaml     ← Require runAsNonRoot: true
│   │       └── disallow-latest-tag.yaml  ← Block :latest image tags
│   │
│   └── external-secrets/
│       ├── values.yaml
│       ├── install.sh
│       └── secret-stores/
│           ├── fake-store.yaml     ← Fake provider for local dev (no real credentials)
│           └── example-secret.yaml ← ExternalSecret example (shows the pattern)
│
├── workloads/
│   ├── hello-world/
│   │   ├── namespace.yaml    ← hello-world namespace
│   │   ├── deployment.yaml   ← traefik/whoami:v1.10.3 — non-root, /health endpoint
│   │   ├── service.yaml      ← ClusterIP service on port 80
│   │   ├── httproute.yaml    ← Gateway API HTTPRoute
│   │   └── install.sh        ← Applies all of the above
│   │
│   ├── network-test/
│   │   ├── namespace.yaml
│   │   ├── test-pods.yaml      ← Two pods in different namespaces for traffic testing
│   │   └── network-policies.yaml ← Policies to test allow/deny behaviour
│   │
│   └── otel-demo/
│       ├── namespace.yaml
│       └── otel-demo.yaml    ← OpenTelemetry demo app (generates traces, metrics, logs)
│
├── tests/
│   ├── smoke/run.sh         ← Nodes ready, system pods, Cilium, CoreDNS, hello-world HTTP
│   ├── networking/run.sh    ← Allowed traffic passes, denied traffic blocked, DNS works
│   ├── observability/run.sh ← Prometheus, Grafana, Loki, Tempo, OTel Collector ready
│   └── security/run.sh      ← cert-manager issues cert, Kyverno policy reports, ESO ready
│
├── docs/
│   ├── implementation-plan.md  ← Phase-by-phase build plan
│   ├── architecture.md         ← Component ownership, data flow, Mermaid diagrams
│   ├── cluster-profiles.md     ← Detailed docs for each of the 3 cluster profiles
│   ├── networking.md           ← Cilium, Gateway API, MetalLB, DNS deep dive
│   ├── observability.md        ← Telemetry flow, Grafana access, example queries
│   ├── troubleshooting.md      ← Diagnose 15+ common failure modes
│   ├── migration-to-eks.md     ← What to change when moving to AWS EKS
│   └── tested-versions.md      ← Record of version combinations that have been verified
│
└── .github/
    └── workflows/
        └── ci.yaml  ← GitHub Actions: shellcheck, yamllint, helm lint, kubeval, markdownlint
```

---

## 4. Architecture decisions

These are the most important design choices made during the session. Understanding these will help you when you start runtime testing.

### CNI: Cilium replaces everything

k3s ships with Flannel as its default CNI, Traefik as its default ingress, and ServiceLB as its default load balancer. **All of these are disabled** in the cluster config files using k3s extra args:

```
--flannel-backend=none
--disable-network-policy
--disable=traefik
--disable=servicelb
--disable-kube-proxy
```

Cilium takes over all of these responsibilities:
- Pod networking (replaces Flannel)
- Network policy enforcement (replaces the built-in controller)
- kube-proxy replacement (handles service ClusterIP/NodePort/LoadBalancer via eBPF)

### Cilium API server IP — the tricky part

When Cilium starts up inside the cluster, it needs to know the address of the Kubernetes API server so it can watch for pods, services, and network policies. In a normal cluster this is straightforward, but in k3d the API server runs in a Docker container, so the address is a **Docker network IP that changes every time you create a new cluster**.

The `networking/cilium/install.sh` script handles this by running:
```bash
docker inspect "k3d-${CLUSTER_NAME}-server-0" \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```
This gets the internal Docker network IP of the k3s server node before running `helm install`. That IP is then passed to Cilium via `--set k8sServiceHost=<IP> --set k8sServicePort=6443`.

> **This is the most likely failure point on first run.** If you see Cilium pods stuck in `Init` or `CrashLoopBackOff`, check that the IP detection worked correctly. You can verify with: `kubectl -n kube-system get pods -l k8s-app=cilium -o wide` and `cilium status`.

### Gateway API: Cilium owns the GatewayClass

The Kubernetes Gateway API is installed by applying the official CRD bundle:
```
https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

When Cilium is installed with Gateway API support enabled, it **automatically creates a GatewayClass named `cilium`**. You do not need to (and should not) create a GatewayClass manually — it would conflict.

The `networking/gateway-api/gateway-class.yaml` file in the repo is kept for documentation purposes only. It is commented out and not applied.

All Gateway and HTTPRoute resources reference `gatewayClassName: cilium`.

### hello-world workload: traefik/whoami

The validation workload uses `traefik/whoami:v1.10.3`. This image:
- Responds to any HTTP request with request details (method, headers, IP) — great for debugging
- Has a `/health` endpoint for readiness/liveness probes
- Runs as a non-root user
- Has a read-only root filesystem
- Is very small (~10MB)

It is reached via the Gateway API HTTPRoute after bootstrap.

### Observability: OTel Collector as the central hub

The full telemetry flow is:

```
Your application (or hello-world)
        │
        ▼
OpenTelemetry Collector (receives OTLP gRPC on :4317, HTTP on :4318)
        │
        ├──► Tempo (traces via OTLP gRPC)
        ├──► Prometheus (metrics via Prometheus remote write)
        └──► Loki (logs via Loki exporter)
                │
                ▼
            Grafana (dashboards for all three datasources)
```

The OTel Collector runs in two modes:
- **DaemonSet** — one pod per node, collects kubelet stats and host metrics
- **Gateway Deployment** — central aggregation point for application telemetry

Grafana datasources for Loki and Tempo are pre-configured inside the `kube-prometheus-stack/values.yaml` so Grafana is ready to use immediately after install.

### Kyverno: Audit mode by default

Kyverno is installed with `validationFailureAction: Audit` on all policies. This means:
- Violations are **reported** in PolicyReport resources but **not blocked**
- Your own workloads won't fail because of the policies during initial setup
- Once you're satisfied the cluster and workloads are compliant, switch individual policies to `Enforce`

### Service mesh and ingress: controlled by env vars

Both are optional and controlled via `.env`:

```bash
SERVICE_MESH=none      # or: istio
INGRESS_PROVIDER=cilium  # or: none, nginx, istio
```

When `SERVICE_MESH=istio`:
- Cilium still owns pod networking
- Istio owns mTLS between services and traffic policy
- The Gateway API controller ownership switches: Istio creates its own GatewayClass

When `INGRESS_PROVIDER=nginx`:
- NGINX Ingress Controller is installed alongside Cilium
- NGINX handles `Ingress` resources
- Gateway API HTTPRoutes are still handled by Cilium

> **Important:** Never enable both Istio and Cilium as Gateway API controllers at the same time. The `install.sh` scripts check for this and will fail clearly.

---

## 5. Component versions

All versions are pinned in `versions.env`. Nothing uses `latest` or `stable`.

| Component | Version | Notes |
|---|---|---|
| k3s | v1.30.2-k3s2 | Kubernetes 1.30 |
| k3d | v5.7.x | Managed separately via brew/install |
| Cilium | 1.15.6 | Helm chart + CLI |
| Gateway API CRDs | 1.1.0 | Standard channel |
| MetalLB | 0.14.5 | Optional, Layer 2 only |
| Istio | 1.22.2 | Sidecar mode, optional |
| kube-prometheus-stack | 61.3.2 | Prometheus + Grafana bundle |
| Loki | 6.6.4 | grafana/loki chart |
| Tempo | 1.10.3 | grafana/tempo chart |
| OpenTelemetry Collector | 0.102.1 | open-telemetry/opentelemetry-collector chart |
| cert-manager | 1.15.1 | jetstack/cert-manager |
| Kyverno | 3.2.6 | kyverno/kyverno |
| External Secrets Operator | 0.10.0 | external-secrets/external-secrets |
| NGINX Ingress | 4.10.1 | ingress-nginx/ingress-nginx |
| hello-world image | traefik/whoami:v1.10.3 | Validation workload |

---

## 6. Cluster profiles

Three cluster profiles are defined. You choose one with `PROFILE=<name>`.

### single-node (default, fastest)

**Use this for:** CNI experiments, Gateway API testing, learning Kubernetes concepts, fast iteration.

```
1 server node, 0 agents
Host ports: 8080→80, 8443→443, 9090→9090
No local registry
Cluster name: k3d-lab
Docker network: k3d-network
```

Default installed components:
- Cilium + Hubble + Hubble UI
- Gateway API CRDs
- hello-world workload

Not installed by default (can enable via `.env`):
- Observability stack
- Security tooling
- Istio
- MetalLB

**Resource usage:** ~2–3 GB Docker memory, light CPU.

### ha (high availability)

**Use this for:** Testing how Kubernetes behaves with multiple control plane nodes, pod scheduling across nodes, disruption testing.

```
3 server nodes, 2 agents = 5 nodes total
Host ports: 8180→80, 8543→443 (via k3d load balancer)
No local registry
Cluster name: k3d-ha
Docker network: k3d-ha-network
```

> Note: In k3d, "HA" means multiple k3s server containers running as Docker containers — not true VM-based HA. The k3d load balancer container fronts the API servers.

**Resource usage:** ~6–8 GB Docker memory. Set Docker Desktop to at least 10 GB for this profile.

### market-dev (full platform)

**Use this for:** Running a realistic development environment for a multi-service application. Includes observability, tracing, and service mesh experimentation.

```
1 server node, 2 agents = 3 nodes total
Host ports: 8280→80, 8643→443, 16686→16686 (Jaeger UI), 3000→3000 (Grafana)
Local registry on port 5000: market-registry.localhost:5000
Cluster name: market-dev
Docker network: k3d-market-network
```

Default installed components:
- Everything from single-node
- kube-prometheus-stack (Prometheus + Grafana)
- Loki
- Tempo
- OpenTelemetry Collector
- Local Path Provisioner StorageClass
- cert-manager
- Kyverno (audit mode)
- External Secrets Operator
- network-test workload
- otel-demo workload

**Resource usage:** ~10–12 GB Docker memory. Set Docker Desktop to at least 14 GB for comfortable use.

---

## 7. How the bootstrap sequence works

When you run `make bootstrap-minimal PROFILE=single-node`, this is what happens step by step:

```
make bootstrap-minimal
    └── bootstrap/install.sh PROFILE=single-node
            │
            ├── 1. bootstrap/prerequisites.sh
            │       Checks: docker, k3d, kubectl, helm, curl, jq
            │       Verifies Docker is running
            │       Prints versions table
            │
            ├── 2. k3d cluster create --config clusters/single-node.yaml
            │       Creates 1 k3s server container
            │       Disables: Flannel, kube-proxy, Traefik, ServiceLB, network policy
            │       Updates kubeconfig automatically
            │       Waits up to 120s for cluster ready
            │
            ├── 3. Wait for nodes Ready
            │       kubectl wait node --all --for=condition=Ready --timeout=120s
            │
            ├── 4. networking/cilium/install.sh
            │       Gets API server IP from Docker inspect
            │       Adds cilium Helm repo
            │       helm upgrade --install cilium cilium/cilium ...
            │       Waits for cilium-operator and cilium DaemonSet ready
            │       Prints cilium status
            │
            ├── 5. networking/gateway-api/install.sh
            │       Applies standard-install.yaml CRDs from kubernetes-sigs
            │       Waits for HTTPRoute CRD to exist
            │       Applies gateway.yaml (gatewayClassName: cilium)
            │       Waits for Gateway to be accepted by Cilium
            │
            ├── 6. workloads/hello-world/install.sh
            │       kubectl apply -f namespace.yaml
            │       kubectl apply -f deployment.yaml
            │       kubectl apply -f service.yaml
            │       kubectl apply -f httproute.yaml
            │       Waits for deployment rollout
            │
            ├── 7. [Optional components if enabled in .env]
            │       observability, security, service mesh, ingress, metallb
            │
            └── 8. bootstrap/validate.sh
                    Checks nodes, system pods, Cilium, CoreDNS, hello-world
                    Prints PASS/FAIL summary
                    Prints access URLs and useful commands
```

---

## 8. Networking deep dive

### Why Cilium?

Cilium uses **eBPF** (extended Berkeley Packet Filter) — a Linux kernel technology that lets you attach programs to kernel events (network packets, system calls, etc.) without modifying kernel source code. This gives Cilium:

- Better performance than iptables-based networking (fewer kernel hops)
- Rich network visibility via Hubble (see every network flow)
- L7-aware network policies (allow HTTP GET but deny POST)
- Native Gateway API support without a separate controller

### Hubble

Hubble is Cilium's built-in network observability layer. After bootstrap:

```bash
# Open the Hubble UI in your browser
cilium hubble ui

# Or port-forward manually:
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# Then open: http://localhost:12000
```

Hubble shows you a real-time graph of network flows between pods, including:
- Which pods are talking to which
- HTTP request paths and response codes
- Dropped packets and which policy dropped them

### Network policies

Three example CiliumNetworkPolicies are included in `networking/cilium/policies/`:

**default-deny.yaml** — applied to a namespace to deny all traffic by default. After applying this, only explicitly allowed traffic works.

**allow-dns.yaml** — required alongside default-deny. Allows pods to reach CoreDNS in kube-system on port 53 (UDP and TCP). Without this, service names cannot be resolved.

**namespace-to-namespace.yaml** — example of allowing traffic from one namespace to another using label selectors.

### Gateway API vs Ingress

The repository uses **Gateway API** (the newer standard) rather than the older `Ingress` resource:

| Feature | Old Ingress | Gateway API |
|---|---|---|
| L7 routing | Basic (host/path) | Rich (headers, methods, weights) |
| Protocol support | HTTP/HTTPS | HTTP, HTTPS, gRPC, TCP |
| Controller binding | Annotation-based | GatewayClass resource |
| Traffic splitting | Controller-specific | Native with weights |
| Status reporting | Limited | Detailed conditions |

The HTTPRoute for hello-world at `networking/gateway-api/routes/hello-world-route.yaml` routes `GET /` traffic to the hello-world service.

### MetalLB (optional)

MetalLB is only needed if you want to test **LoadBalancer-type Services** with real IP addresses on your local network. k3d already handles NodePort and host port mapping, so MetalLB is not required for most use cases.

If you do enable it (`INSTALL_METALLB=true`), the `install.sh` script reads the Docker network subnet for your cluster and allocates a small pool of IPs from that range for MetalLB to assign.

---

## 9. Observability stack

### Components and their roles

| Component | Role | Port |
|---|---|---|
| Prometheus | Scrapes metrics from all components | 9090 |
| Grafana | Dashboards for metrics, logs, traces | 3000 |
| Loki | Log aggregation and querying | 3100 |
| Tempo | Distributed trace storage and querying | 3200 |
| OTel Collector | Receives OTLP telemetry, routes to backends | 4317 (gRPC), 4318 (HTTP) |

All components live in the `observability` namespace.

### Accessing Grafana

After `make bootstrap-market`:

```bash
# Port-forward Grafana
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80

# Or if using market-dev profile, port 3000 is already mapped to the host
# Open: http://localhost:3000
# Default credentials: admin / prom-operator (or check the values.yaml)
```

Grafana comes pre-configured with three datasources:
- **Prometheus** — for metrics
- **Loki** — for logs (query with LogQL)
- **Tempo** — for traces (query with TraceQL or by trace ID)

### Useful Grafana queries

Once you have Grafana open:

**Prometheus — see hello-world HTTP request count:**
```
sum(rate(traefik_http_requests_total[5m])) by (code)
```

**Loki — see logs from hello-world:**
```
{namespace="hello-world"}
```

**Tempo — find recent traces:**
Use the Explore view, select Tempo datasource, click "Search" tab.

### OTel Collector configuration

The collector at `observability/opentelemetry/collectors/collector.yaml` accepts telemetry on:
- `:4317` — OTLP gRPC (use for services inside the cluster)
- `:4318` — OTLP HTTP (use for services that prefer HTTP/JSON)

To send traces from your own application to the collector:
```python
# Python example using opentelemetry-sdk
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
exporter = OTLPSpanExporter(endpoint="http://otel-collector.observability:4317")
```

---

## 10. Security tooling

### cert-manager

cert-manager manages TLS certificates inside Kubernetes. It is set up with two issuers:

**SelfSigned issuer** (`issuers/selfsigned-issuer.yaml`):
- Signs certificates with itself
- Good for bootstrapping a local CA

**CA issuer** (`issuers/ca-issuer.yaml`):
- Uses a locally generated CA certificate
- Signs certificates that look like real TLS certs
- No public DNS or Let's Encrypt required

Test that it works:
```bash
kubectl apply -f security/cert-manager/issuers/test-certificate.yaml
kubectl describe certificate -n cert-manager test-cert
# Should show: Status: True, Reason: Ready
```

### Kyverno policies

Four policies are included in `security/kyverno/policies/`. All are in **Audit mode** — violations are logged but not blocked.

| Policy | What it checks |
|---|---|
| disallow-privileged.yaml | No containers with `privileged: true` |
| require-resources.yaml | All containers must have CPU and memory requests AND limits |
| require-non-root.yaml | All containers must have `runAsNonRoot: true` |
| disallow-latest-tag.yaml | No container images tagged `:latest` |

View policy violations:
```bash
kubectl get policyreport -A
kubectl describe policyreport -n hello-world
```

Switch a policy to Enforce mode (will start blocking violations):
```bash
# Edit the policy and change:
# validationFailureAction: Audit
# to:
# validationFailureAction: Enforce
kubectl apply -f security/kyverno/policies/disallow-privileged.yaml
```

### External Secrets Operator

ESO is installed but configured with a **fake provider** for local development (`secret-stores/fake-store.yaml`). This lets you test the ExternalSecret workflow without needing real cloud credentials.

For production use on EKS, you would replace the fake store with an AWS Secrets Manager SecretStore:
```yaml
# What it would look like on EKS:
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa  # IRSA-annotated service account
```

---

## 11. Testing strategy

Four test suites are in `tests/`. Each is a self-contained bash script that returns exit code 0 on success and 1 on failure.

### Smoke tests (`tests/smoke/run.sh`)

The fastest and most important tests. Run these after every bootstrap:

```bash
make test-smoke
```

Checks:
1. `kubectl get nodes` shows all nodes Ready
2. System pods in `kube-system` are Running
3. `cilium status` shows healthy (if cilium CLI installed)
4. CoreDNS pods are running
5. hello-world pods are Running and Available
6. hello-world service has endpoints
7. HTTP request to hello-world returns 200

### Networking tests (`tests/networking/run.sh`)

```bash
make test-networking
```

Checks:
1. Pod A can reach Pod B when allowed by network policy
2. Pod A cannot reach Pod C when denied by network policy
3. DNS still works under a default-deny policy (allow-dns.yaml is in effect)
4. Cross-namespace traffic is handled correctly by policy

### Observability tests (`tests/observability/run.sh`)

```bash
make test-observability
```

Checks:
1. Prometheus pod is ready
2. Grafana pod is ready
3. Loki pod is ready
4. Tempo pod is ready
5. OTel Collector pod is ready
6. Prometheus has at least one scraped metric (queries API)

### Security tests (`tests/security/run.sh`)

```bash
make test-security
```

Checks:
1. cert-manager issues a test certificate successfully
2. Kyverno PolicyReport exists and has results
3. External Secrets Operator pod is ready
4. No real credentials are committed (scans for AWS keys, etc.)

---

## 12. Key commands — cheat sheet

### Cluster lifecycle

```bash
# First time setup
cp .env.example .env
make prerequisites

# Create minimal cluster (fast, ~2 min)
make bootstrap-minimal PROFILE=single-node

# Create full market-dev cluster (slow, ~10-15 min)
make bootstrap-market PROFILE=market-dev

# Delete a cluster
make cluster-delete CLUSTER_NAME=k3d-lab
make cluster-delete CLUSTER_NAME=market-dev

# Reset (delete + recreate)
make cluster-reset PROFILE=single-node

# Get cluster info / access URLs
make cluster-info

# Diagnose problems
make doctor
```

### Component management

```bash
# Cilium
make cilium-install
make cilium-uninstall
make cilium-status
make cilium-test          # runs cilium connectivity test (takes ~5 min)

# Gateway API
make gateway-api-install

# Observability
make observability-install
make observability-uninstall

# Security
make security-install
make security-uninstall

# Istio
make istio-install
make istio-uninstall
make istio-status

# MetalLB
make metallb-install
make metallb-uninstall

# Storage
make storage-install
make storage-test

# Workloads
make workloads-install
make workloads-uninstall
```

### Testing

```bash
make test-smoke
make test-networking
make test-observability
make test-security
make test-all
make validate
```

### Useful kubectl one-liners

```bash
# See all pods across all namespaces
kubectl get pods -A

# Watch pods in real time
kubectl get pods -A -w

# Get Cilium pod logs
kubectl logs -n kube-system -l k8s-app=cilium --tail=50

# Check Gateway status
kubectl get gateway -A
kubectl describe gateway -n default

# Check HTTPRoute status
kubectl get httproute -A

# Port-forward to Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Port-forward to Grafana
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80

# Check Kyverno policy violations
kubectl get policyreport -A

# Check cert-manager certificates
kubectl get certificate -A

# Check External Secrets
kubectl get externalsecret -A
kubectl get secretstore -A
```

---

## 13. What has NOT been tested yet

This entire repository was built in a single Claude Code CLI session. The files were written and syntax-checked but **no Kubernetes cluster was actually created**. The following have not been run:

- `make prerequisites` — not executed
- `make bootstrap-minimal` — not executed
- `make test-smoke` — not executed
- Any actual Helm chart installation
- Any actual pod scheduling
- Any actual network policy testing
- Any certificate issuance
- Any Grafana dashboard loading

This is normal for a first session. The files are designed to work, but runtime issues are expected and should be diagnosed and fixed when you first run the bootstrap.

---

## 14. Recommended next steps when back at your laptop

Work through this list in order. Stop and fix issues before moving on.

### Step 1: Install prerequisites

```bash
# Install k3d
brew install k3d

# Install cilium CLI
brew install cilium-cli

# Install Task (for Taskfile.yml support)
brew install go-task

# Verify everything
make prerequisites
```

### Step 2: Run minimal bootstrap

```bash
cd ~/projects/hegarty/k3d-lab
cp .env.example .env

make bootstrap-minimal PROFILE=single-node
```

Watch the output carefully. Expected sequence:
1. Prerequisites check — all green
2. k3d cluster created — `k3d-lab` context in kubeconfig
3. Nodes ready
4. Cilium installed and healthy
5. Gateway API CRDs applied
6. hello-world deployed
7. Validate script — all green

### Step 3: Verify the cluster

```bash
kubectl get nodes
kubectl get pods -A
cilium status
make test-smoke
```

### Step 4: Test networking

```bash
make test-networking
```

This tests network policies. If this fails, check that Cilium is fully ready first (`cilium status`).

### Step 5: Run the full market-dev bootstrap

Only attempt this after single-node is working:

```bash
make cluster-delete CLUSTER_NAME=k3d-lab

# Edit .env to enable observability and security:
# INSTALL_OBSERVABILITY=true
# INSTALL_SECURITY=true

make bootstrap-market PROFILE=market-dev
make test-all
```

### Step 6: Access the UIs

```bash
# Hubble (network flows)
cilium hubble ui
# → http://localhost:12000

# Grafana (metrics, logs, traces)
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# → http://localhost:3000 (admin / prom-operator)
```

---

## 15. Known risks and gotchas

### Cilium API server IP detection

**Risk:** The Docker network IP of the k3s server node may not match what we detect with `docker inspect`.

**Symptom:** Cilium pods stuck in `Init:0/1` or `CrashLoopBackOff`.

**Diagnosis:**
```bash
kubectl -n kube-system describe pod -l k8s-app=cilium | grep -A5 "Events:"
kubectl -n kube-system logs -l k8s-app=cilium --previous
```

**Fix:** Edit `networking/cilium/install.sh` and hard-code the API server IP temporarily, or try a different detection method:
```bash
# Alternative: get IP from kubectl endpoints
kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}'
```

### kube-proxy replacement in k3d

**Risk:** Cilium's kube-proxy replacement requires eBPF, which requires a recent Linux kernel. On macOS, Docker Desktop runs a Linux VM — the kernel version in that VM matters.

**Symptom:** Cilium agent logs show errors about missing eBPF features.

**Fix:** Update Docker Desktop to the latest version (which uses a newer kernel). Or disable kube-proxy replacement in `networking/cilium/values.yaml`:
```yaml
kubeProxyReplacement: false
```
(and remove `--disable-kube-proxy` from the cluster yaml, then recreate the cluster)

### Docker Desktop memory

**Risk:** Docker Desktop defaults to 8 GB. The market-dev profile with observability can use 10–12 GB.

**Symptom:** Pods pending with `Insufficient memory` or OOMKilled.

**Fix:** Docker Desktop → Settings → Resources → Memory → set to 14 GB or more.

### Port conflicts

**Risk:** Ports 8080, 8443, 9090 (single-node) or 8280, 8643, 3000 (market-dev) may already be in use on your Mac.

**Symptom:** k3d cluster creation fails with "port already in use".

**Fix:** Check what's using the port: `lsof -i :8080`. Stop the conflicting process or edit the cluster yaml to use different host ports.

### Cilium connectivity test

The `cilium connectivity test` command (`make cilium-test`) deploys a set of test workloads and runs ~70 tests. It takes 5–15 minutes and requires significant cluster resources. It is **disabled by default** (`CILIUM_CONNECTIVITY_TEST=false` in `.env.example`). Enable it only when you want a thorough Cilium validation.

### Kyverno blocking workloads

If you switch Kyverno policies from Audit to Enforce, deployments that don't comply with the policies will be rejected by the admission webhook. The hello-world workload is designed to comply with all four policies, but if you add your own workloads they may be blocked.

---

*Session completed: 2026-07-23*
*Repository: `~/projects/hegarty/k3d-lab`*
*91 files created, 28 shell scripts syntax-validated*
*Next action: `make prerequisites` then `make bootstrap-minimal PROFILE=single-node`*
