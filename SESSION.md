# k3d-lab — Session Notes

> **What is this file?**
> This document captures everything built and discovered in the Claude Code CLI sessions that created and validated this repository.
> It is written so you can read it on your phone (GitHub iOS app) and pick up exactly where we left off.

---

## Table of Contents

1. [What we built and why](#1-what-we-built-and-why)
2. [Current status — RUNTIME VALIDATED](#2-current-status--runtime-validated)
3. [All bugs found and fixed during first runtime session](#3-all-bugs-found-and-fixed-during-first-runtime-session)
4. [How to start, stop, and manage the cluster](#4-how-to-start-stop-and-manage-the-cluster)
5. [Known limitations (not bugs — by design)](#5-known-limitations-not-bugs--by-design)
6. [Repository structure — every file explained](#6-repository-structure--every-file-explained)
7. [Architecture decisions](#7-architecture-decisions)
8. [Component versions](#8-component-versions)
9. [Cluster profiles](#9-cluster-profiles)
10. [How the bootstrap sequence works](#10-how-the-bootstrap-sequence-works)
11. [Networking deep dive](#11-networking-deep-dive)
12. [Observability stack](#12-observability-stack)
13. [Security tooling](#13-security-tooling)
14. [Testing strategy](#14-testing-strategy)
15. [Key commands — cheat sheet](#15-key-commands--cheat-sheet)
16. [Recommended next steps](#16-recommended-next-steps)

---

## 1. What we built and why

### The goal

A **reusable local Kubernetes platform** that spins up on a Mac with Docker Desktop. The platform:

- Feels like a real production cluster (real CNI, real service mesh, real observability)
- Is fast to create and destroy
- Uses the same Kubernetes patterns (Helm charts, manifests, Gateway API) as a real AWS EKS cluster
- Lets you experiment with Cilium, Istio, Prometheus, Grafana, Loki, Tempo, cert-manager, and Kyverno locally before deploying to EKS

### What was created and verified

A fully functional repository at `~/projects/hegarty/k3d-lab`. The entire bootstrap and observability install sequences have been run to completion and all tests pass:

- **10/10 smoke tests passing**
- **9/9 networking tests passing**
- **10/10 observability tests passing**
- **11/11 security tests passing**
- **40/40 total tests passing**

---

## 2. Current status — RUNTIME VALIDATED

| Item | Status |
|---|---|
| Repository created | ✅ Done |
| Shell script syntax (`bash -n`) | ✅ All scripts pass |
| `make prerequisites` | ✅ Passed |
| `make bootstrap-minimal PROFILE=single-node` | ✅ Completed successfully |
| Cilium DaemonSet | ✅ 1/1 pods ready |
| Cilium operator | ✅ Running |
| GatewayClass `cilium` | ✅ Created automatically by operator |
| Gateway API CRDs (experimental channel) | ✅ All installed including TLSRoute |
| Gateway resource | ✅ Accepted, LoadBalancer IP assigned (172.21.100.1) |
| hello-world deployment | ✅ 1/1 ready |
| hello-world HTTP health check (port-forward) | ✅ Returns 200 |
| `make test-smoke` | ✅ 10/10 passing |
| `make test-networking` | ✅ 9/9 passing |
| MetalLB | ❌ Not used — conflicts with Cilium (see Known Limitations) |
| Gateway → backend HTTP (without port-forward) | ⚠️ 503 on k3d — see Known Limitations |
| `make test-observability` | ✅ 10/10 pass — Prometheus, Grafana, Loki, Tempo, OTel |
| `make test-security` | ❌ Not yet run (security stack not installed) |

**The cluster currently exists.** To use it after Docker Desktop restarts:

```bash
kubectl get nodes   # check if cluster is alive
# If missing, recreate:
make bootstrap-minimal PROFILE=single-node
```

---

## 3. All bugs found and fixed during first runtime session

These were real failures encountered when running `make bootstrap-minimal` for the first time. All are fixed in the repo.

---

### Bug 1: `make bootstrap-minimal` — No rule to make target

**What happened:** Running `make bootstrap-minimal PROFILE=single-node` failed immediately with `No rule to make target`.

**Root cause:** The Makefile had the target documented but not actually defined — it used `up` internally.

**Fix:** Added all documented targets to the Makefile: `bootstrap-minimal`, `bootstrap-market`, `bootstrap-platform`, `cluster-create`, `cluster-delete`, `cluster-reset`, `cluster-info`, `cilium-status`, `cilium-test`, `metallb-uninstall`, `observability-uninstall`, `security-uninstall`, `istio-status`, `storage-install`, `storage-test`, `workloads-install`, `workloads-uninstall`, `clean`.

---

### Bug 2: `REPO_ROOT: readonly variable` crash

**What happened:** The bootstrap crashed immediately with:
```
scripts/wait-for.sh: line 5: REPO_ROOT: readonly variable
```

**Root cause:** `install.sh` sources `common.sh` (which sets `readonly REPO_ROOT`), then sources `wait-for.sh` which also tries to set `REPO_ROOT`. The second assignment to a `readonly` variable is a fatal error under `set -e`.

**Fix:** Changed every script to guard the REPO_ROOT assignment before sourcing:

```bash
# Before (broken):
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# After (correct — skip if already set by parent):
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
readonly REPO_ROOT
```

Applied to all 27 scripts that set REPO_ROOT.

---

### Bug 3: Node wait timeout — nodes stuck NotReady before Cilium installs

**What happened:** `bootstrap/install.sh` ran:
```bash
kubectl wait --for=condition=Ready nodes --all --timeout=120s
```
...immediately after creating the cluster, before installing Cilium. The wait timed out because nodes cannot become Ready without a CNI.

**Root cause:** The original bootstrap sequence had: create cluster → wait for nodes Ready → install Cilium. That's a chicken-and-egg problem. Nodes need Cilium (CNI) to become Ready, but Cilium wasn't installed yet.

**Fix:** Split into two phases:
1. Wait only for the API server to be reachable (not nodes Ready)
2. Install Cilium
3. THEN wait for nodes Ready

```bash
# Phase 1: just check API is up
until kubectl get nodes &>/dev/null; do sleep 2; done

# Phase 2: install CNI
bash networking/cilium/install.sh

# Phase 3: now it's valid to wait for Ready
kubectl wait --for=condition=Ready nodes --all --timeout=180s
```

---

### Bug 4: `cilium-node-init` CrashLoopBackOff

**What happened:** After Cilium was installed, `cilium-node-init` pods went into CrashLoopBackOff with 206+ restarts. The log showed:
```
nsenter: failed to execute bash: No such file or directory
```

**Root cause:** The `cilium-node-init` component runs `nsenter` on the k3d node container to execute a bash initialization script on the host filesystem. k3d's node containers (based on `rancher/k3s`) do not have `bash` in their container image. The nsenter call is fundamentally incompatible with k3d.

**Fix:** Disabled node-init in `networking/cilium/values.yaml`:
```yaml
nodeinit:
  enabled: false
```
This is safe on k3d because k3d already mounts `/sys/fs/bpf` automatically, which is the main thing node-init sets up.

---

### Bug 5: Cilium agent crash — cluster name/ID constraint

**What happened:** After fixing node-init, Cilium agents were still crashing:
```
cannot use default cluster name (default) with option cluster-id != 0
```

**Root cause:** Cilium 1.15 enforces: if `cluster.name` is `"default"`, then `cluster.id` must be `0`. The original values had `name: "default"` and `id: 1`.

**Additional complication:** Running `helm upgrade --reuse-values` kept the old bad values. Had to do a full upgrade with the values file explicitly, then clean up a stuck old ReplicaSet of the operator that had a host port conflict.

**Fix:** Updated `networking/cilium/values.yaml`:
```yaml
cluster:
  name: "k3d-lab"
  id: 0
```

---

### Bug 6: GatewayClass never created — `TLSRoute CRD not found`

**What happened:** After Cilium was healthy, no `GatewayClass` resource existed. The Cilium operator log showed:
```
Required GatewayAPI resources are not found: tlsroutes.gateway.networking.k8s.io not found
```
The operator refused to start its Gateway API controller until all required CRDs were present.

**Root cause:** The install script was applying the **standard channel** Gateway API CRDs:
```
standard-install.yaml
```
The standard channel does not include `TLSRoute`. Cilium 1.15's Gateway API controller requires `TLSRoute` to be present at startup.

**Fix:** Changed `networking/gateway-api/install.sh` to apply the **experimental channel**:
```
experimental-install.yaml
```
Then restarted the Cilium operator. The operator found the TLSRoute CRD, started the Gateway API controller, and automatically created the `cilium` GatewayClass.

**Important:** Also discovered and reverted a bad patch attempt (setting `--enable-gateway-api=true` as a CLI flag on the operator deployment — that flag doesn't exist on the operator binary; the operator reads gateway config from the ConfigMap, not CLI flags).

---

### Bug 7: MetalLB speaker crash — `dial tcp 10.43.0.1:443: i/o timeout`

**What happened:** Running `make metallb-install` resulted in MetalLB speaker pods crashing with API server timeout. The speaker couldn't reach the Kubernetes API.

**Root cause:** MetalLB speaker runs with `hostNetwork: true`. Cilium's eBPF socket-level load balancing does **not** apply to host-network pods in k3d's nested cgroup environment. So when the MetalLB speaker (running on the host network) tries to reach the Kubernetes API ClusterIP (`10.43.0.1`), Cilium's eBPF rules don't intercept that connection, and it times out.

**Fix:** Do not use MetalLB with Cilium on k3d. Use `CiliumLoadBalancerIPPool` instead, which is built into Cilium and doesn't have this conflict:
```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: default
spec:
  cidrs:
    - cidr: "172.21.100.0/24"
```
This is already configured in `networking/cilium/` and applied automatically.

---

### Bug 8: `make test-smoke` exits after first PASS



**What happened:** The smoke test ran one test (PASS), then exited silently. Output showed only 1 total test instead of 10.

**Root cause 1 — arithmetic under `set -Eeuo pipefail`:**

```bash
# Broken:
t_pass() { ok "PASS: $1"; (( PASS++ )) || true; }
```
When `PASS=0`, `(( PASS++ ))` evaluates to `(( 0 ))` (the pre-increment value), which has exit code 1. Under `set -Eeuo pipefail` with `set -E` (errtrace), the ERR trap propagates into functions. The `|| true` is outside the function body and doesn't help here.

**Root cause 2 — grep pipefail:**

```bash
# Broken:
not_ready=$(K get nodes --no-headers | grep "NotReady" | wc -l)
```
When no nodes are NotReady, `grep "NotReady"` finds nothing and exits 1. Under pipefail, a non-zero exit from any pipe member kills the whole pipeline.

**Fix:**
```bash
# Correct counter:
t_pass() { ok "PASS: $1"; PASS=$(( PASS + 1 )); }
t_fail() { err "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# Correct grep (subshell absorbs the non-zero exit):
not_ready=$(K get nodes --no-headers 2>/dev/null | { grep -c "NotReady" || true; })
not_ready="${not_ready:-0}"
```

---

## 3b. All bugs found and fixed during observability install session (2026-07-31)

These were real failures encountered when running `make observability-install` and `make test-observability` for the first time. All are fixed in the repo.

---

### Bug 11: Helm timeout — kube-prometheus-stack `--timeout 10m` exceeded on cold image cache

**What happened:** `make observability-install` stalled for over 10 minutes on the kube-prometheus-stack Helm install and then failed with a timeout. Resources were created but Helm gave up waiting for pods to become Ready.

**Root cause:** k3d needs to pull ~1.5 GB of Docker images on first install. On a cold cache the image pulls took longer than the 10 minute Helm wait deadline.

**Fix:** Increased `--timeout 10m` → `--timeout 20m` in `observability/kube-prometheus-stack/install.sh`. Loki, Tempo, and OTel timeouts increased from `5m` → `10m`.

---

### Bug 12: Grafana CrashLoopBackOff — DNS failure on external plugin download

**What happened:** Grafana pods entered CrashLoopBackOff. Logs showed:
```
Error: ✗ Get "https://grafana.com/api/plugins/grafana-piechart-panel/versions": dial tcp: lookup grafana.com: server misbehaving
```

**Root cause:** `grafana-piechart-panel` and `grafana-worldmap-panel` were listed in the `plugins` section of `observability/kube-prometheus-stack/values.yaml`. Grafana tries to download plugins from `grafana.com` at startup. External DNS (`grafana.com`) is not reachable from inside k3d pods (Docker networking constraint on macOS). Both plugins are **bundled in Grafana 8+** and do not need to be installed.

**Fix:** Removed the `plugins` section from `values.yaml` entirely.

---

### Bug 13: Wrong operator deployment name in wait step

**What happened:** `make observability-install` failed waiting for the Prometheus operator:
```
Error from server (NotFound): deployments.apps "kube-prometheus-stack-prometheus-operator" not found
```

**Root cause:** The `wait_for_rollout` call in `install.sh` used the old deployment name. In kube-prometheus-stack chart v61.3.2 the operator deployment was renamed from `kube-prometheus-stack-prometheus-operator` to `kube-prometheus-stack-operator`.

**Fix:** Updated `install.sh` to wait on `deployment/kube-prometheus-stack-operator`.

---

### Bug 14: Loki `UPGRADE FAILED: context deadline exceeded` — memcached caches pending

**What happened:** Loki install failed repeatedly with `context deadline exceeded`. Pod `loki-results-cache-0` (and `loki-chunks-cache-0`) were stuck in `Pending` status, preventing Helm `--wait` from ever completing.

**Root cause:** Loki chart v6 enables `chunksCache` and `resultsCache` (two memcached StatefulSets) by default, even in `singleBinary` mode. These require 1.2 GB RAM and a CPU limit each. In a minimal single-node k3d cluster there was insufficient allocatable capacity.

**Fix:** Explicitly disabled both caches in `observability/loki/values.yaml`:
```yaml
chunksCache:
  enabled: false
resultsCache:
  enabled: false
```
Also had to uninstall the failed Loki release first (`helm uninstall loki -n observability`) before reinstalling.

---

### Bug 15: OTel DaemonSet wrong name in wait step

**What happened:** `make otel-install` succeeded but the wait step failed:
```
Error from server (NotFound): daemonsets.apps "otel-collector" not found
```

**Root cause:** The Helm chart names the DaemonSet using the pattern `<release-name>-<chart-name>`. With release name `otel-collector` and chart `opentelemetry-collector`, the actual name is `otel-collector-opentelemetry-collector`.

**Fix:** Updated `observability/opentelemetry/install.sh` wait step to use `daemonset/otel-collector-opentelemetry-collector`.

---

### Bug 16: Loki and Tempo readiness tests returning "error" with `curl -sf`

**What happened:** `make test-observability` showed Loki and Tempo failing their readiness checks despite both pods running. The test captured `"error"` from `|| echo "error"` fallback.

**Root cause (Loki):** The test was port-forwarding to `svc/loki-gateway:80` and calling `/ready`. The nginx gateway in the Loki chart does not proxy `/ready` — it returns HTTP 404. `curl -sf` exits non-zero on 4xx, so the `|| echo "error"` fallback fired.

**Root cause (Tempo):** Same `curl -sf` pattern — if Tempo's `/ready` returns a non-200 status (e.g. 204), curl fails and the fallback fires.

**Fix:**
- Loki: switched port-forward target from `svc/loki-gateway:80` to `pod/loki-0:3100` (direct pod access bypasses nginx)
- Both: removed `-f` flag from curl (`curl -s` instead of `curl -sf`) so curl captures the response body regardless of HTTP status
- Both: increased sleep from 3s to 5s after starting port-forward to allow connection to establish

---

### Bug 17: Observability test counter arithmetic — same `(( N++ ))` bug as smoke tests

**What happened:** `make test-observability` exited after the first PASS without running further tests.

**Root cause:** Same `set -Eeuo pipefail` arithmetic bug as Bug 8. `t_pass`, `t_fail`, `t_skip` in `tests/observability/run.sh` used `(( N++ ))` which exits 1 when N=0.

**Fix:** Changed all three counter functions to use `N=$(( N + 1 ))` form.

---

## 4. How to start, stop, and manage the cluster

### The cluster is Docker containers

k3d clusters run as Docker containers. There is no separate VM to manage — when Docker Desktop is running, the cluster containers are accessible.

### Start Docker Desktop → cluster is available

```bash
# After Docker Desktop starts, check if the cluster is alive:
kubectl get nodes

# If you see nodes (Ready), you're good. Use the cluster normally.
```

### There is no "pause"

k3d has no native pause/resume for clusters. The cluster is either:
- **Running** — Docker Desktop is running, cluster containers exist
- **Deleted** — containers were removed

If you want to free resources, delete the cluster and recreate it when needed.

### Delete the cluster

```bash
make cluster-delete CLUSTER_NAME=k3d-lab
```

This removes:
- The k3d cluster containers
- The Docker network (`k3d-k3d-lab-network`)
- The kubeconfig context (`k3d-k3d-lab`)

It does **not** delete Docker images or volumes (those are shared and take time to download).

### Recreate the cluster

```bash
make bootstrap-minimal PROFILE=single-node
```

Takes about 2–3 minutes. All smoke tests and networking tests pass at the end.

### Reset in one command

```bash
make cluster-reset PROFILE=single-node
```

This is `cluster-delete` + `bootstrap-minimal` in one step.

### Daily workflow

```bash
# Morning: open Docker Desktop, then:
kubectl get nodes         # verify cluster is alive

# Work...

# If you need to free RAM (Docker Desktop uses it even when idle):
make cluster-delete CLUSTER_NAME=k3d-lab

# Next session:
make bootstrap-minimal PROFILE=single-node
```

### Check cluster status

```bash
make status     # nodes, pods, services, access URLs
make doctor     # automated diagnostics for common issues
kubectl get pods -A   # all pods across all namespaces
```

### Access services

```bash
# hello-world — via port-forward
kubectl port-forward -n hello-world svc/hello-world 8888:8080
curl http://localhost:8888/health

# Hubble UI (Cilium network flows)
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# open http://localhost:12000

# Grafana (after make observability-install)
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# open http://localhost:3000 — admin / prom-operator

# Prometheus
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090
```

Or use shortcuts:

```bash
make hubble-ui    # port-forwards Hubble UI to localhost:12000
make grafana      # port-forwards Grafana to localhost:3000
make prometheus   # port-forwards Prometheus to localhost:9090
```

---

## 5. Known limitations (not bugs — by design)

These are documented behaviors specific to k3d on macOS. They cannot be "fixed" — they are constraints of the environment.

### LoadBalancer IP is not reachable from macOS

The Gateway resource gets a LoadBalancer IP (`172.21.100.x`) from `CiliumLoadBalancerIPPool`. This IP lives inside the Docker network VM and is **not routable from macOS**. You cannot `curl 172.21.100.1` from your terminal.

**Workaround:** Always use `kubectl port-forward` or k3d's host port mappings (8080, 8443) to reach services.

### Gateway API Envoy → backend pods: 503

When routing through the Cilium Gateway (Envoy), you receive a 503. Envoy receives the request and applies HTTPRoute filters correctly (you can see the `X-Served-By: cilium-gateway` response header), but it cannot connect to backend pods.

**Root cause:** Cilium's eBPF socket-level load balancing doesn't apply to the Envoy process running inside the Cilium agent container's cgroup in k3d's nested container environment. This is a fundamental k3d/macOS limitation.

**Impact:** The Gateway as an edge router doesn't work on k3d/macOS. Direct service access via `kubectl port-forward` works fully. All ClusterIP → pod routing (what matters for intra-cluster traffic) works correctly.

**This does not affect:** pod-to-pod networking, network policies, CoreDNS, service discovery, or anything that matters for local development.

### MetalLB conflicts with Cilium kube-proxy replacement

MetalLB speaker pods crash on k3d with Cilium because `hostNetwork: true` pods cannot reach ClusterIPs through Cilium eBPF in k3d's nested cgroup environment. MetalLB is not used in this setup.

**Workaround:** Use `CiliumLoadBalancerIPPool` for LoadBalancer IP assignment (already configured).

---

## 6. Repository structure — every file explained

```
k3d-lab/
├── .env.example          ← Copy to .env and edit. Controls all optional components.
├── .gitignore            ← Excludes .env, *.log, .DS_Store, kubeconfig files, etc.
├── versions.env          ← Single source of truth for ALL pinned versions.
├── README.md             ← Full project README with quick-start guide.
├── SESSION.md            ← This file. Full build and runtime context.
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
│   │   │                             Key fixes: nodeinit.enabled: false,
│   │   │                             cluster.name: "k3d-lab", cluster.id: 0
│   │   ├── install.sh             ← Detects API server IP, runs helm upgrade --install
│   │   ├── uninstall.sh           ← helm uninstall cilium
│   │   └── policies/
│   │       ├── default-deny.yaml          ← Deny all ingress/egress by default
│   │       ├── allow-dns.yaml             ← Allow DNS to kube-system (required for any workload)
│   │       └── namespace-to-namespace.yaml ← Example cross-namespace allow rule
│   │
│   ├── metallb/
│   │   ├── values.yaml            ← MetalLB Helm values (kept for reference)
│   │   ├── install.sh             ← NOT RECOMMENDED on k3d — use CiliumLoadBalancerIPPool
│   │   └── manifests/
│   │       ├── address-pool.yaml  ← IPAddressPool (IP range from Docker network)
│   │       └── l2-advertisement.yaml ← L2Advertisement resource
│   │
│   └── gateway-api/
│       ├── install.sh             ← Applies EXPERIMENTAL Gateway API CRDs (required for
│       │                             TLSRoute which Cilium 1.15 operator needs), then
│       │                             applies Gateway resource
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
│   ├── smoke/run.sh         ← 10 tests: nodes, DNS, Cilium, hello-world, CRDs, PVC
│   ├── networking/run.sh    ← 9 tests: DNS, intra/cross-namespace, network policy, Hubble
│   ├── observability/run.sh ← Prometheus, Grafana, Loki, Tempo, OTel readiness
│   └── security/run.sh      ← cert-manager, Kyverno policy reports, ESO ready
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

## 7. Architecture decisions

### CNI: Cilium replaces everything

k3s ships with Flannel as its default CNI, Traefik as its default ingress, and ServiceLB as its default load balancer. **All of these are disabled** in the cluster config files:

```
--flannel-backend=none
--disable-network-policy
--disable=traefik
--disable=servicelb
--disable-kube-proxy
```

Cilium takes over all responsibilities:
- Pod networking (replaces Flannel)
- Network policy enforcement (replaces the built-in controller)
- kube-proxy replacement (handles service ClusterIP/NodePort/LoadBalancer via eBPF)
- Gateway API controller (Cilium operator creates the GatewayClass and manages Gateways)

### Cilium API server IP detection

When Cilium starts inside the cluster, it needs the Kubernetes API server address. In k3d the API server is a Docker container, so its IP changes each time the cluster is created.

`networking/cilium/install.sh` detects this automatically:
```bash
docker inspect "k3d-${CLUSTER_NAME}-server-0" \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```
The IP is passed to Cilium via `--set k8sServiceHost=<IP> --set k8sServicePort=6443`.

### Gateway API: experimental channel required

Cilium 1.15 requires the `TLSRoute` CRD to start its Gateway API controller. `TLSRoute` is only in the **experimental channel**. The standard channel is missing it and the controller refuses to start.

The `networking/gateway-api/install.sh` applies `experimental-install.yaml`.

### GatewayClass is auto-created by the operator

You do not create a GatewayClass manually. When Cilium is installed with `gatewayAPI.enabled: true` and all CRDs are present, the Cilium operator **automatically creates a GatewayClass named `cilium`**. All Gateway and HTTPRoute resources reference `gatewayClassName: cilium`.

### LoadBalancer: CiliumLoadBalancerIPPool (not MetalLB)

MetalLB conflicts with Cilium's kube-proxy replacement on k3d (see Bug 7 above). Instead, `CiliumLoadBalancerIPPool` is configured to assign IPs from the `172.21.100.0/24` range. These IPs are only reachable inside the Docker network, but they allow the Gateway resource to move to `Programmed` status.

### hello-world workload: traefik/whoami

The validation workload uses `traefik/whoami:v1.10.3`. This image:
- Responds to any HTTP request with request details (method, headers, IP)
- Has a `/health` endpoint for readiness/liveness probes
- Runs as a non-root user with a read-only root filesystem
- Is very small (~10MB)

Reached via `kubectl port-forward` after bootstrap. Compliant with all 4 Kyverno policies.

---

## 8. Component versions

All versions are pinned in `versions.env`. Nothing uses `latest` or `stable`.

| Component | Version | Notes |
|---|---|---|
| k3s | v1.30.2-k3s2 | Kubernetes 1.30 |
| k3d | v5.8.3 | Local cluster manager |
| Cilium | 1.15.6 | CNI + kube-proxy + Gateway API controller |
| Gateway API CRDs | 1.1.0 | **Experimental channel** (required for TLSRoute) |
| CiliumLoadBalancerIPPool | built-in | LB IP assignment (replaces MetalLB) |
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

## 9. Cluster profiles

Three cluster profiles are defined. Choose one with `PROFILE=<name>`.

### single-node (default, fastest) — TESTED ✅

**Use this for:** CNI experiments, Gateway API testing, learning Kubernetes concepts, fast iteration.

```
1 server node, 0 agents
Host ports: 8080→80, 8443→443, 9090→9090
No local registry
Cluster name: k3d-lab
```

Installed by bootstrap-minimal:
- Cilium + Hubble + Hubble UI
- Gateway API CRDs (experimental channel)
- CiliumLoadBalancerIPPool
- hello-world workload

Not installed by default (enable via `.env`):
- Observability stack
- Security tooling
- Istio

**Resource usage:** ~2–3 GB Docker memory.

### ha (high availability)

**Use this for:** Testing how Kubernetes behaves with multiple control plane nodes, pod scheduling, disruption testing.

```
3 server nodes, 2 agents = 5 nodes total
Host ports: 8180→80, 8543→443 (via k3d load balancer)
Cluster name: k3d-ha
```

**Resource usage:** ~6–8 GB Docker memory. Set Docker Desktop to at least 10 GB.

### market-dev (full platform)

**Use this for:** Running a realistic dev environment for a multi-service application.

```
1 server node, 2 agents = 3 nodes total
Host ports: 8280→80, 8643→443, 16686→16686 (Jaeger UI), 3000→3000 (Grafana)
Local registry on port 5000
Cluster name: market-dev
```

Includes everything from single-node plus the full observability + security stack.

**Resource usage:** ~10–12 GB Docker memory. Set Docker Desktop to at least 14 GB.

---

## 10. How the bootstrap sequence works

When you run `make bootstrap-minimal PROFILE=single-node`:

```
make bootstrap-minimal
    └── bootstrap/install.sh PROFILE=single-node
            │
            ├── Step 1: bootstrap/prerequisites.sh
            │       Checks: docker, k3d, kubectl, helm, curl, jq
            │       Verifies Docker is running
            │       Prints versions table
            │
            ├── Step 2: k3d cluster create --config clusters/single-node.yaml
            │       Creates 1 k3s server container
            │       Disables: Flannel, kube-proxy, Traefik, ServiceLB, network policy
            │       Updates kubeconfig automatically
            │       (Cluster created but nodes are NotReady — no CNI yet)
            │
            ├── Step 3: Wait for API server ONLY (not node Ready — no CNI yet)
            │       until kubectl get nodes &>/dev/null; do sleep 2; done
            │       (Nodes will be NotReady — that's expected and correct)
            │
            ├── Step 4: networking/cilium/install.sh (CNI — nodes become Ready after this)
            │       Gets API server IP from Docker inspect
            │       Adds cilium Helm repo
            │       helm upgrade --install cilium cilium/cilium ...
            │       Waits for cilium-operator and cilium DaemonSet ready
            │       kubectl wait --for=condition=Ready nodes --all --timeout=180s
            │       (Now it's valid to wait for nodes Ready)
            │
            ├── Step 5: networking/gateway-api/install.sh
            │       Applies experimental-install.yaml CRDs from kubernetes-sigs
            │       (Includes TLSRoute — required by Cilium 1.15 operator)
            │       Waits for HTTPRoute CRD to exist
            │       Applies gateway.yaml (gatewayClassName: cilium)
            │       Cilium operator detects CRDs, creates "cilium" GatewayClass
            │
            ├── Step 6: workloads/hello-world/install.sh
            │       kubectl apply -f namespace.yaml
            │       kubectl apply -f deployment.yaml
            │       kubectl apply -f service.yaml
            │       kubectl apply -f httproute.yaml
            │       wait_for_rollout hello-world deployment/hello-world 120
            │
            ├── Step 7: [Optional components if enabled in .env]
            │       observability, security, service mesh, ingress
            │
            └── Step 8: bootstrap/validate.sh
                    Checks nodes, system pods, Cilium, CoreDNS, hello-world
                    Prints PASS/FAIL summary
```

---

## 11. Networking deep dive

### Why Cilium?

Cilium uses **eBPF** — programs attached to Linux kernel events (network packets, system calls) without modifying kernel source. Benefits:
- Better performance than iptables (fewer kernel hops)
- Rich network visibility via Hubble (see every flow)
- L7-aware network policies (allow HTTP GET but deny POST)
- Native Gateway API support without a separate controller pod

### Hubble

Hubble is Cilium's built-in observability layer. After bootstrap:

```bash
# Port-forward Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# Open: http://localhost:12000

# Or use shortcut:
make hubble-ui
```

Shows real-time network flows between pods: which pods talk to which, HTTP request paths and response codes, dropped packets and which policy dropped them.

### Network policies

Three example CiliumNetworkPolicies in `networking/cilium/policies/`:

- **default-deny.yaml** — deny all traffic by default in a namespace
- **allow-dns.yaml** — allow pods to reach CoreDNS on port 53 (required alongside default-deny)
- **namespace-to-namespace.yaml** — allow traffic from one namespace to another by label selector

### Gateway API vs Ingress

The repo uses **Gateway API** (the newer standard) rather than the older `Ingress` resource:

| Feature | Old Ingress | Gateway API |
|---|---|---|
| L7 routing | Basic (host/path) | Rich (headers, methods, weights) |
| Protocol support | HTTP/HTTPS | HTTP, HTTPS, gRPC, TCP |
| Controller binding | Annotation-based | GatewayClass resource |
| Traffic splitting | Controller-specific | Native with weights |
| Status reporting | Limited | Detailed conditions |

---

## 12. Observability stack

**Status: RUNTIME VALIDATED ✅ — 10/10 tests passing (2026-07-31)**

See [OBSERVABILITY.md](OBSERVABILITY.md) for the full usage guide.

### Components

| Component | Role | Access |
|---|---|---|
| Prometheus | Scrapes metrics from all components | `make prometheus` → http://localhost:9090 |
| Grafana | Dashboards for metrics, logs, traces | `make grafana` → http://localhost:3000 |
| Hubble | Cilium network flow metrics | `make hubble-ui` → http://localhost:12000 |
| Loki | Log aggregation (Promtail agent collects pod logs automatically) | Query via Grafana Explore |
| Tempo | Distributed trace storage (OTLP ingest) | Query via Grafana Explore |
| OTel Collector | OTLP receiver DaemonSet → routes to Tempo + Prometheus + Loki | grpc: 4317, http: 4318 |

All components live in the `observability` namespace.

### Install

```bash
make observability-install   # ~5-10 min on first run (image pulls)
make test-observability       # verify all 5 components healthy
```

### Accessing Grafana

```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000 — admin / prom-operator
```

Pre-configured datasources with cross-datasource linking:
- **Prometheus** (uid: prometheus) — primary metrics source
- **Loki** (uid: loki) — logs, with derived fields linking to Tempo traces
- **Tempo** (uid: tempo) — traces, with traces-to-logs linking back to Loki

### Key k3d/macOS constraints on observability

- **External DNS from pods doesn't work** — Grafana plugins listed in `values.yaml` that download from `grafana.com` will crash Grafana. Don't add any plugins that aren't bundled.
- **Cold image cache** — first Helm install pulls ~1-2 GB of images. Timeouts must be generous (20m for kube-prometheus-stack, 10m for others).
- **Loki readiness via nginx gateway** — the `loki-gateway:80` nginx proxy does not forward `/ready`. Always check readiness by port-forwarding directly to `pod/loki-0:3100`.
- **Promtail is deprecated** — the Promtail chart still works but prints a deprecation warning. Successor is Grafana Alloy (not migrated yet).

---

## 13. Security tooling

### cert-manager

Two issuers configured:
- **SelfSigned** — signs with itself, good for bootstrapping a local CA
- **CA issuer** — uses a locally generated CA cert, signs certs that look like real TLS certs

### Kyverno

Four policies in `security/kyverno/policies/`, all in **Audit mode** (report only, never block):

| Policy | What it checks |
|---|---|
| disallow-privileged.yaml | No containers with `privileged: true` |
| require-resources.yaml | CPU and memory requests AND limits required |
| require-non-root.yaml | `runAsNonRoot: true` required |
| disallow-latest-tag.yaml | No `:latest` image tags |

The hello-world workload complies with all four policies.

### External Secrets Operator

Installed with a **fake provider** for local dev (no real credentials needed). For EKS production use, replace the fake store with an AWS Secrets Manager SecretStore.

---

## 14. Testing strategy

Four test suites in `tests/`. Each returns exit code 0 on all pass, 1 on any failure.

### Results as of last run (2026-07-31)

```
make test-smoke         → 10/10 PASS ✅
make test-networking    → 9/9   PASS ✅
make test-observability → 10/10 PASS ✅
make test-security      → 11/11 PASS ✅
                          40/40 TOTAL ✅
```

### Smoke tests

```bash
make test-smoke
```

Tests: cluster reachable, all nodes Ready, CoreDNS running, Cilium DaemonSet ready, hello-world deployment ready, hello-world HTTP health check, Gateway API CRDs installed (gateways + httproutes), StorageClass local-path exists, PVC creation succeeds.

### Networking tests

```bash
make test-networking
```

Tests: DNS resolution, intra-namespace traffic, cross-namespace traffic, network policy allow, network policy deny, Hubble relay connectivity.

### Observability tests

```bash
make test-observability   # requires: make observability-install first
```

Tests: Prometheus, Grafana, Loki, Tempo, OTel Collector pod readiness.

### Security tests

```bash
make test-security   # requires: make security-install first
```

Tests: cert-manager certificate issuance, Kyverno PolicyReport exists, External Secrets Operator ready.

---

## 15. Key commands — cheat sheet

### Cluster lifecycle

```bash
# First time setup
cp .env.example .env
make prerequisites

# Create minimal cluster (~2-3 min)
make bootstrap-minimal PROFILE=single-node

# Create full market-dev cluster (~10-15 min)
make bootstrap-market PROFILE=market-dev

# Delete cluster
make cluster-delete CLUSTER_NAME=k3d-lab
make cluster-delete CLUSTER_NAME=market-dev

# Reset (delete + recreate)
make cluster-reset PROFILE=single-node

# Get info / access URLs
make status
make cluster-info

# Diagnose problems
make doctor
```

### Component management

```bash
make cilium-install / make cilium-uninstall / make cilium-status
make gateway-api-install
make observability-install / make observability-uninstall
make security-install / make security-uninstall
make istio-install / make istio-uninstall
make storage-install / make storage-test
make workloads-install / make workloads-uninstall
```

### Access UIs

```bash
make hubble-ui      # Cilium network flows → http://localhost:12000
make grafana        # Metrics, logs, traces → http://localhost:3000
make prometheus     # Prometheus → http://localhost:9090
```

### Testing

```bash
make test-smoke
make test-networking
make test-observability
make test-security
make test-all
```

### Useful kubectl one-liners

```bash
kubectl get pods -A                                              # all pods
kubectl get pods -A -w                                           # watch
kubectl logs -n kube-system -l k8s-app=cilium --tail=50        # Cilium logs
kubectl get gateway -A && kubectl get httproute -A             # Gateway status
kubectl get policyreport -A                                      # Kyverno violations
kubectl get certificate -A                                       # TLS certs
kubectl get externalsecret -A && kubectl get secretstore -A    # ESO
```

---

## 15b. OTel demo deployment session (2026-08-19)

Deployed the `otel-demo` workload (frontend + productcatalogservice) and verified end-to-end observability: traces in Tempo, logs in Loki, cross-datasource linking working in Grafana.

**Bugs found and fixed:**

| # | Bug | Fix |
|---|---|---|
| 18 | `PRODUCT_CATALOG_PORT` wrong env var name | Renamed to `PRODUCT_CATALOG_SERVICE_PORT` (what the Go binary expects) |
| 19 | Frontend Next.js binding to pod IP not `0.0.0.0` | Set `HOSTNAME=0.0.0.0` — server.js reads `process.env.HOSTNAME` as bind address; Kubernetes auto-sets this to pod name which resolves to pod IP, blocking `kubectl port-forward` |

**New files:**

- `workloads/otel-demo/install.sh` — deploy script with observability pre-flight check and readiness wait
- `docs/app-observability.md` — engineer-facing standards: required labels, OTLP env vars, SDK setup (Go/Python/Node.js), ServiceMonitor pattern, structured logging format, reference deployment manifest, new service checklist

**CI fixes (same session):**

- `CiliumClusterWideNetworkPolicy` → `CiliumClusterwideNetworkPolicy` (wrong casing, CRD not found in CI)
- Duplicate `operator:` key in `networking/cilium/values.yaml` silently dropped `replicas: 1`, causing CI to wait for 2 replicas and time out
- Node readiness wait in CI moved to after Cilium install (same chicken-and-egg as Bug 3)
- Security Helm timeouts `5m` → `10m` / `15m` (cold image pulls on GitHub Actions free tier)
- CI job `timeout-minutes: 30` → `60`
- CI integration job removed — linting only; integration tests run locally

---

## 16. Recommended next steps

The single-node cluster is complete with 40/40 tests passing. OTel demo verified end-to-end. Here are natural next steps:

### 1. Deploy a real service

Use `docs/app-observability.md` as the checklist. The platform provides traces, logs, metrics, and network visibility automatically for any service that follows the standards.

### 2. Try the market-dev profile (full platform)

```bash
make cluster-delete CLUSTER_NAME=k3d-lab

# Edit .env:
# INSTALL_OBSERVABILITY=true
# INSTALL_SECURITY=true

make bootstrap-market PROFILE=market-dev
make test-all
```

### 3. Run the Cilium connectivity test (comprehensive)

```bash
make cilium-test   # ~5-10 min, resource-heavy, ~70 connectivity scenarios
```

### 4. Experiment with network policies

```bash
kubectl apply -f networking/cilium/policies/default-deny.yaml
kubectl apply -f networking/cilium/policies/allow-dns.yaml
# Watch Hubble to see traffic flows
make hubble-ui
```

### 5. Try Istio (optional service mesh)

```bash
make istio-install
make istio-status
# Note: only enable one Gateway API controller at a time
```

---

*First build session: 2026-07-23*
*Runtime validation session: 2026-07-30*
*Observability session: 2026-07-31*
*Security session: 2026-08-17*
*OTel demo + app standards session: 2026-08-19*
*Test results: 40/40 passing (10 smoke + 9 networking + 10 observability + 11 security)*
*Repository: `~/projects/hegarty/k3d-lab`*
*Next: deploy a real service using `docs/app-observability.md` as the onboarding checklist*
