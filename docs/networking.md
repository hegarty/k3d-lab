# Networking

## Overview

k3d-lab uses Cilium as the sole networking component, replacing Flannel, kube-proxy, and a traditional ingress controller.

## Cilium

### What Cilium does in this lab

| Function | How |
|----------|-----|
| CNI (pod networking) | VXLAN tunnel between nodes |
| kube-proxy replacement | eBPF service load balancing |
| NetworkPolicy | CiliumNetworkPolicy + standard Kubernetes NetworkPolicy |
| Gateway API controller | Manages HTTPRoute, GatewayClass, Gateway |
| Observability | Hubble L3-L7 flow visibility |

### Installation

Cilium is installed with kube-proxy replacement enabled. The API server IP must be provided at install time so Cilium can reach it without kube-proxy:

```bash
# Automatic (done by bootstrap/install.sh)
bash networking/cilium/install.sh
```

The install script:
1. Gets the server container's IP on the Docker network
2. Installs Cilium via Helm with `k8sServiceHost` and `k8sServicePort` set
3. Applies the allow-dns network policy

### Hubble UI

Hubble provides real-time network flow visualization:

```bash
# Port-forward
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Open http://localhost:12000
# Select a namespace to see flows
```

Hubble metrics are collected by Prometheus automatically.

## Gateway API

### GatewayClass

Cilium registers a GatewayClass named `cilium` automatically after installation. Do not create a manual GatewayClass — it will conflict.

```bash
# Verify
kubectl get gatewayclass
# NAME     CONTROLLER                      ACCEPTED   AGE
# cilium   io.cilium/gateway-controller    True       5m
```

### Gateway

A shared Gateway is created in `kube-system`:

```yaml
# networking/gateway-api/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: k3d-gateway
  namespace: kube-system
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

### HTTPRoutes

Each workload creates its own HTTPRoute referencing the shared Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-namespace
spec:
  parentRefs:
    - name: k3d-gateway
      namespace: kube-system
      sectionName: http
  hostnames:
    - "my-app.localhost"
  rules:
    - backendRefs:
        - name: my-app
          port: 8080
```

**Access:**
```bash
# Via host-header (route to specific service)
curl -H "Host: my-app.localhost" http://localhost:8080/

# On macOS, add to /etc/hosts or use dnsmasq for *.localhost
```

## Network Policies

### Standard Kubernetes NetworkPolicy

Standard `NetworkPolicy` resources work via Cilium's implementation:

```bash
kubectl apply -f workloads/network-test/network-policies.yaml
```

### CiliumNetworkPolicy

CiliumNetworkPolicy extends standard NetworkPolicy with:
- L7 HTTP method/path filtering
- DNS-name based egress filtering
- Cluster-wide policies (CiliumClusterWideNetworkPolicy)

Example — allow only GET /api:
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-api-get
  namespace: my-app
spec:
  endpointSelector:
    matchLabels:
      app: my-app
  ingress:
    - fromEndpoints:
        - matchLabels:
            role: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: /api/.*
```

### Default Deny

To enable zero-trust networking:

```bash
# Apply allow-dns first (very important!)
kubectl apply -f networking/cilium/policies/allow-dns.yaml

# Then apply default deny
kubectl apply -f networking/cilium/policies/default-deny.yaml

# Now add explicit allow policies for each service
```

## MetalLB (Optional)

MetalLB provides LoadBalancer type services in k3d. Without MetalLB, services of type LoadBalancer remain in `<pending>` state.

```bash
# Install
INSTALL_METALLB=true ./bootstrap/install.sh
# or
bash networking/metallb/install.sh
```

MetalLB automatically detects the Docker network CIDR and allocates IPs from the `.100.200-.100.250` range.

## Debugging

### Check pod connectivity

```bash
# Create a debug pod
kubectl run debug --image=nicolaka/netshoot:v0.12 --rm -it -- bash

# From inside:
curl http://hello-world.hello-world.svc.cluster.local:8080/health
nslookup kubernetes.default.svc.cluster.local
```

### Check Cilium agent status

```bash
# Per-node status
kubectl exec -n kube-system ds/cilium -- cilium status

# Flow monitoring (requires Hubble relay)
cilium hubble observe --namespace hello-world

# Endpoint list
kubectl exec -n kube-system ds/cilium -- cilium endpoint list
```

### Check Gateway API

```bash
# Gateway status
kubectl get gateway -A
kubectl describe gateway k3d-gateway -n kube-system

# HTTPRoute status
kubectl get httproute -A
kubectl describe httproute hello-world -n hello-world

# Check route is programmed
kubectl get httproute hello-world -n hello-world \
  -o jsonpath='{.status.parents[0].conditions}'
```
