# Cluster Profiles

Three cluster profiles are provided, each tuned for different use cases.

## single-node

**File:** `clusters/single-node.yaml`

```
Servers: 1   Agents: 0
RAM: ~2GB    Startup: ~30s
```

One control plane node that runs both control plane and workloads. The simplest setup — good for:
- Quick feature development and testing
- CI/CD pipelines where resource efficiency matters
- Learning Kubernetes concepts
- Testing manifests before deploying to multi-node clusters

**Port mappings:**

| Host Port | K8s Port | Purpose |
|-----------|----------|---------|
| 8080 | 80 | HTTP ingress |
| 8443 | 443 | HTTPS ingress |
| 9090 | 9090 | Prometheus direct access |

**Usage:**
```bash
CLUSTER_PROFILE=single-node ./bootstrap/install.sh
# or just:
./bootstrap/install.sh  # single-node is default
```

**Limitations:**
- No `topologySpreadConstraints` enforcement (only one node)
- No pod anti-affinity testing
- No node failure simulation

## ha

**File:** `clusters/ha.yaml`

```
Servers: 3   Agents: 2
RAM: ~6GB    Startup: ~2-3 min
```

High-availability setup with an embedded etcd cluster across 3 server nodes and 2 worker nodes. Use for:
- Testing pod scheduling and anti-affinity rules
- Simulating node failures (`docker stop k3d-k3d-ha-server-1`)
- Verifying HA workload behavior
- Testing PodDisruptionBudgets
- Testing topologySpreadConstraints

**Port mappings (via k3d loadbalancer):**

| Host Port | K8s Port | Purpose |
|-----------|----------|---------|
| 8180 | 80 | HTTP ingress |
| 8543 | 443 | HTTPS ingress |

**Usage:**
```bash
CLUSTER_PROFILE=ha CLUSTER_NAME=k3d-ha ./bootstrap/install.sh
```

**Simulating node failure:**
```bash
# Stop a worker node
docker stop k3d-k3d-ha-agent-0

# Watch pod rescheduling
kubectl get pods -A -w

# Restart the node
docker start k3d-k3d-ha-agent-0
```

**Resource requirements:**
- Docker Desktop: 8GB RAM, 4 CPUs minimum

## market-dev

**File:** `clusters/market-dev.yaml`

```
Servers: 1   Agents: 2   Registry: yes
RAM: ~8GB    Startup: ~2-3 min
```

Full-featured development cluster with:
- Local container registry on port 5000
- 2 worker nodes for realistic scheduling
- Port mappings for Grafana and Jaeger UI

Use for:
- Full stack development with local image builds
- Testing with the full observability stack
- Microservices development with multiple services
- Simulating production-like workload distribution

**Port mappings:**

| Host Port | K8s Port | Purpose |
|-----------|----------|---------|
| 8280 | 80 | HTTP ingress |
| 8643 | 443 | HTTPS ingress |
| 16686 | 16686 | Jaeger UI |
| 3000 | 3000 | Grafana direct |
| 5000 | — | Local registry |

**Usage:**
```bash
CLUSTER_PROFILE=market-dev CLUSTER_NAME=market-dev ./bootstrap/install.sh
```

**Using the local registry:**
```bash
# Build and push an image
docker build -t myapp:v1.0 .
docker tag myapp:v1.0 market-registry.localhost:5000/myapp:v1.0
docker push market-registry.localhost:5000/myapp:v1.0

# Reference in a pod/deployment
image: market-registry.localhost:5000/myapp:v1.0
```

**Resource requirements:**
- Docker Desktop: 12GB RAM, 6 CPUs recommended

## Switching Between Profiles

You can run multiple profiles simultaneously (different cluster names and networks):

```bash
# Start single-node
CLUSTER_PROFILE=single-node CLUSTER_NAME=k3d-lab ./bootstrap/install.sh

# Start HA (different name, different network)
CLUSTER_PROFILE=ha CLUSTER_NAME=k3d-ha ./bootstrap/install.sh

# Switch kubectl context
kubectl config use-context k3d-k3d-lab
kubectl config use-context k3d-k3d-ha
```

## Customizing Profiles

Copy an existing cluster YAML and modify:

```bash
cp clusters/single-node.yaml clusters/my-profile.yaml
# Edit: name, agents, ports, extraArgs...
CLUSTER_PROFILE=my-profile ./bootstrap/install.sh
```

## k3s Configuration

All profiles disable these k3s built-ins (replaced by Cilium):

| Component | k3s Default | Our Setting | Why |
|-----------|-------------|-------------|-----|
| Traefik | enabled | disabled | Cilium Gateway API replaces it |
| ServiceLB (klipper) | enabled | disabled | MetalLB or Cilium handles LB |
| Network policy | enabled | disabled | Cilium handles this with eBPF |
| Flannel | enabled | none | Cilium replaces Flannel |
| kube-proxy | enabled | disabled | Cilium eBPF replaces kube-proxy |
