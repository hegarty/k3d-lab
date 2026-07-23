# Architecture

## Overview

k3d-lab is a local Kubernetes platform that mirrors common production patterns. It uses k3d to run k3s clusters inside Docker containers, with Cilium providing eBPF-based networking, Gateway API for ingress, and a full observability stack.

```
┌─────────────────────────────────────────────────────────────────┐
│  macOS Host                                                       │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Docker Desktop                                               │ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │  k3d Cluster (Docker network: k3d-network)              │ │ │
│  │  │                                                          │ │ │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │ │ │
│  │  │  │  Server-0    │  │   Agent-0    │  │   Agent-1    │  │ │ │
│  │  │  │  (container) │  │  (container) │  │  (container) │  │ │ │
│  │  │  │              │  │              │  │              │  │ │ │
│  │  │  │  ┌─────────┐ │  │  ┌─────────┐│  │  ┌─────────┐ │  │ │ │
│  │  │  │  │  k3s    │ │  │  │  k3s    ││  │  │  k3s    │ │  │ │ │
│  │  │  │  │ control │ │  │  │ worker  ││  │  │ worker  │ │  │ │ │
│  │  │  │  │ plane   │ │  │  │         ││  │  │         │ │  │ │ │
│  │  │  │  └─────────┘ │  │  └─────────┘│  │  └─────────┘ │  │ │ │
│  │  │  │  ┌─────────┐ │  │  ┌─────────┐│  │  ┌─────────┐ │  │ │ │
│  │  │  │  │ Cilium  │ │  │  │ Cilium  ││  │  │ Cilium  │ │  │ │ │
│  │  │  │  │ Agent   │ │  │  │ Agent   ││  │  │ Agent   │ │  │ │ │
│  │  │  │  └─────────┘ │  │  └─────────┘│  │  └─────────┘ │  │ │ │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘  │ │ │
│  │  │                                                          │ │ │
│  │  │  k3d LoadBalancer (nginx)                                │ │ │
│  │  │  Port: 8080 → 80, 8443 → 443                            │ │ │
│  │  └─────────────────────────────────────────────────────────┘ │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  localhost:8080 ──→ ingress                                       │
│  localhost:8443 ──→ ingress                                       │
└─────────────────────────────────────────────────────────────────┘
```

## Component Architecture

### Networking Layer

```
Internet / localhost
        │
        ▼
  k3d port mapping
  (host:8080 → node:80)
        │
        ▼
  Cilium Gateway API
  (GatewayClass: cilium)
        │
        ├── HTTPRoute: hello-world → hello-world:8080
        ├── HTTPRoute: otel-demo  → frontend:8080
        └── HTTPRoute: grafana    → grafana:80
              │
              ▼
         Pod Network (VXLAN)
         IPAM: kubernetes
         kube-proxy replacement: Cilium eBPF
```

### Observability Stack

```
Application Pods
      │  OTLP (gRPC:4317 / HTTP:4318)
      ▼
OTel Collector (DaemonSet)
      │
      ├──── Traces ──→ Tempo (port 4317)
      │                  │
      │                  └──→ Grafana (Tempo datasource)
      │
      ├──── Metrics ─→ Prometheus (remote write)
      │                  │
      │                  └──→ Grafana (Prometheus datasource)
      │
      └──── Logs ───→ Loki (push API)
                       │
                       └──→ Grafana (Loki datasource)

Node Logs: Promtail (DaemonSet) ──→ Loki
Cilium:    Hubble relay ──→ Hubble UI
```

### Security Architecture

```
Kubernetes API Server
        │
        ├── Kyverno (Admission Webhook)
        │     ├── disallow-privileged
        │     ├── disallow-latest-tag
        │     ├── require-resources
        │     └── require-non-root
        │
        ├── cert-manager
        │     ├── selfsigned-issuer (bootstrap)
        │     └── k3d-lab-ca-issuer (workload certs)
        │
        └── External Secrets Operator
              └── ClusterSecretStore: fake-store (local dev)
                  ClusterSecretStore: aws-ssm (production)
```

## Data Flow

### Request Flow (single-node)

```
curl http://localhost:8080 -H "Host: hello-world.localhost"
        │
        ▼
k3d port mapping: host:8080 → container:80
        │
        ▼
Cilium Gateway (kube-system)
        │  HTTPRoute lookup: hello-world.localhost → hello-world/hello-world:8080
        ▼
hello-world Service (ClusterIP)
        │
        ▼
hello-world Pod (traefik/whoami)
        │
        ▼
Response: "Hostname: hello-world-xxx\nIP: 10.42.x.x\n..."
```

### Trace Flow

```
Application code
  │  OpenTelemetry SDK
  │  OTLP export
  ▼
OTel Collector (DaemonSet on same node)
  │  traces pipeline
  ▼
Tempo (OTLP gRPC:4317)
  │  stored in local filesystem
  ▼
Grafana (Tempo datasource)
  │  TraceQL queries
  ▼
Grafana Explore / Dashboard
```

## Network CIDR Allocation

| Network | CIDR | Usage |
|---------|------|-------|
| Docker | 172.18.0.0/16 | k3d container IPs |
| Pod network | 10.42.0.0/16 | Kubernetes pod IPs (k3s default) |
| Service network | 10.43.0.0/16 | Kubernetes service ClusterIPs |
| MetalLB pool | 172.18.100.200-250 | LoadBalancer IPs (optional) |

## Design Decisions

### Why Cilium instead of Flannel?

k3s ships with Flannel by default. Cilium replaces it with eBPF-based networking because:
- **kube-proxy replacement**: Cilium handles service load balancing in eBPF, eliminating iptables and improving performance
- **Gateway API controller**: Cilium implements Gateway API natively, removing the need for a separate ingress controller
- **Hubble**: Built-in network observability at Layer 3-7
- **Network policies**: CiliumNetworkPolicy offers L7-aware policies (HTTP methods, DNS names)
- **EKS parity**: AWS's EKS supports Cilium as a networking add-on, making this setup directly portable

### Why Gateway API instead of Ingress?

- **Future standard**: Gateway API is the successor to Ingress in the Kubernetes ecosystem
- **Role-based**: Separates infrastructure (GatewayClass, Gateway) from application (HTTPRoute) concerns
- **Feature-rich**: Native support for traffic splitting, header modification, gRPC routing, and TLS passthrough

### Why k3d instead of kind or minikube?

- **Speed**: k3d clusters start in 30-60 seconds
- **Multi-node**: Supports HA clusters with multiple server and agent nodes
- **Registry**: Built-in local registry support for `market-dev` profile
- **k3s compatibility**: k3s is a CNCF certified Kubernetes distribution used in production
