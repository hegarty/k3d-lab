# Troubleshooting

## Common Issues

### Cilium pods are not starting

**Symptom:** `kubectl get pods -n kube-system` shows Cilium pods in `Pending`, `Init:0/1`, or `CrashLoopBackOff`

**Check:**
```bash
kubectl describe pod -n kube-system -l k8s-app=cilium
kubectl logs -n kube-system -l k8s-app=cilium --previous
```

**Cause 1: Wrong API server IP**

The `k8sServiceHost` was set to an incorrect IP. Cilium requires the exact IP of the API server as seen from inside the Docker network.

**Fix:**
```bash
# Get the correct IP
docker inspect k3d-k3d-lab-server-0 \
  --format '{{(index .NetworkSettings.Networks "k3d-k3d-lab").IPAddress}}'

# Reinstall Cilium with correct IP
helm upgrade cilium cilium/cilium -n kube-system \
  --reuse-values \
  --set k8sServiceHost=<correct-ip> \
  --set k8sServicePort=6443
```

**Cause 2: BPF filesystem not mounted**

In some Docker Desktop versions, the BPF filesystem is not mounted.

**Fix:**
```bash
# Check if nodeinit is enabled in values.yaml
# networking/cilium/values.yaml should have:
# nodeinit:
#   enabled: true

# Reinstall with nodeinit
helm upgrade cilium cilium/cilium -n kube-system \
  --reuse-values \
  --set nodeinit.enabled=true
```

---

### No GatewayClass after Cilium install

**Symptom:** `kubectl get gatewayclass` returns empty or `cilium` not found

**Cause:** Cilium operator hasn't registered the GatewayClass yet, or Gateway API CRDs aren't installed.

**Fix:**
```bash
# Install Gateway API CRDs first
bash networking/gateway-api/install.sh

# Restart Cilium operator
kubectl rollout restart deployment/cilium-operator -n kube-system

# Wait and check
kubectl get gatewayclass
```

---

### HTTPRoute shows status "Not Accepted"

**Check:**
```bash
kubectl describe httproute hello-world -n hello-world
# Look for conditions under status.parents
```

**Cause 1:** Gateway not found (wrong namespace or name in `parentRefs`)

**Fix:** Ensure `parentRefs` matches the Gateway exactly:
```yaml
parentRefs:
  - name: k3d-gateway      # must match gateway name
    namespace: kube-system  # must match gateway namespace
```

**Cause 2:** No allowed routes (namespace restriction)

**Fix:** Check `gateway.yaml` — `allowedRoutes.namespaces.from` should be `All`:
```yaml
allowedRoutes:
  namespaces:
    from: All
```

---

### DNS resolution failing inside pods

**Symptom:** `nslookup kubernetes.default.svc.cluster.local` fails from a pod

**Check:**
```bash
kubectl run debug --image=busybox:1.36 --rm -it -- nslookup kubernetes.default.svc.cluster.local
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

**Cause 1:** CoreDNS not running

**Fix:**
```bash
kubectl rollout restart deployment/coredns -n kube-system
```

**Cause 2:** Network policy blocking DNS (if default-deny is applied)

**Fix:**
```bash
# Apply the allow-dns policy
kubectl apply -f networking/cilium/policies/allow-dns.yaml
```

---

### Port-forward doesn't work / connection refused

**Symptom:** `curl http://localhost:8080` returns "connection refused"

**Cause 1:** No pod is ready to serve traffic

**Fix:**
```bash
kubectl get pods -n hello-world
kubectl rollout status deployment/hello-world -n hello-world
```

**Cause 2:** Gateway hasn't assigned an address yet

**Fix:**
```bash
kubectl get gateway k3d-gateway -n kube-system
# Check ADDRESS field — should show an IP

# If pending, check Cilium Gateway controller
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-operator
```

**Cause 3:** Port already in use on host

**Fix:**
```bash
lsof -i :8080
# Kill the conflicting process or change k3d port mapping
```

---

### Helm install fails with "context deadline exceeded"

**Cause:** Resource constraints — Docker Desktop doesn't have enough memory.

**Fix:**
```bash
# Check Docker memory
docker info --format '{{.MemTotal}}'

# Increase in Docker Desktop: Settings → Resources → Memory → 8GB+

# Or install with longer timeout
helm upgrade --install cilium cilium/cilium \
  --timeout 10m \
  ...
```

---

### Cluster creation fails: "network already exists"

**Symptom:** `k3d cluster create` fails with network conflict

**Fix:**
```bash
# List Docker networks
docker network ls | grep k3d

# Remove stale network
docker network rm k3d-k3d-lab

# Retry cluster creation
```

---

### Kyverno webhook causing admission failures

**Symptom:** Pod creation fails with `webhook "validate.kyverno.svc" denied the request`

**Cause:** A Kyverno policy in `Enforce` mode is blocking the pod.

**Diagnosis:**
```bash
# See which policy fired
kubectl get policyreport -A
kubectl describe policyreport -n my-namespace

# Check policy details
kubectl get clusterpolicy disallow-privileged -o yaml
```

**Fix (temporary — switch to Audit):**
```bash
kubectl patch clusterpolicy disallow-privileged \
  --type=merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'
```

**Fix (permanent — add exception):**
```yaml
# Add to the policy
exclude:
  any:
    - resources:
        namespaces: [my-namespace]
```

---

### cert-manager certificate stuck in "Not Ready"

**Check:**
```bash
kubectl describe certificate my-cert -n my-namespace
kubectl describe certificaterequest -n my-namespace
kubectl logs -n cert-manager deployment/cert-manager
```

**Cause:** CA certificate not yet created (timing issue during install)

**Fix:**
```bash
# Check CA cert exists
kubectl get secret k3d-lab-ca-secret -n cert-manager

# If missing, re-run selfsigned issuer
kubectl apply -f security/cert-manager/issuers/selfsigned-issuer.yaml

# Wait, then re-apply CA issuer
sleep 15
kubectl apply -f security/cert-manager/issuers/ca-issuer.yaml
```

---

### Prometheus has no targets

**Check:**
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets
```

**Cause:** RBAC — Prometheus can't list ServiceMonitors in other namespaces

**Fix:** The `serviceMonitorSelectorNilUsesHelmValues: false` in values.yaml should allow all namespaces. If still broken:
```bash
kubectl get clusterrole kube-prometheus-stack-prometheus
kubectl get clusterrolebinding kube-prometheus-stack-prometheus
```

---

## Useful Diagnostic Commands

```bash
# Full cluster status
bash scripts/cluster-info.sh

# Doctor
bash scripts/doctor.sh

# Cilium status
kubectl exec -n kube-system ds/cilium -- cilium status

# Cilium endpoint list
kubectl exec -n kube-system ds/cilium -- cilium endpoint list

# Watch all events
kubectl get events -A --sort-by='.lastTimestamp' -w

# Describe failing pod
kubectl describe pod <name> -n <namespace>

# Previous container logs
kubectl logs <pod> -n <namespace> --previous

# All resource status
kubectl get all -A

# k3d cluster details
k3d cluster list
k3d node list
```

## Reset / Nuclear Option

If everything is broken:

```bash
# Destroy and recreate
bash bootstrap/reset.sh

# Or manually
k3d cluster delete k3d-lab
k3d cluster create --config clusters/single-node.yaml
```
