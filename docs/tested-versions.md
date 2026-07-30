# Tested Versions

This document records which versions have been validated together.

## Current Baseline (July 2026)

| Component | Version | Chart Version | Status |
|-----------|---------|--------------|--------|
| k3d | 5.7.x | — | Tested |
| k3s | v1.30.2-k3s2 | — | Tested |
| Kubernetes | 1.30.2 | — | Tested |
| Cilium | 1.15.6 | 1.15.6 | Tested |
| Gateway API CRDs | 1.1.0 | — | Tested |
| MetalLB | 0.14.5 | 0.14.5 | Tested |
| Istio | 1.22.2 | 1.22.2 | Tested |
| kube-prometheus-stack | — | 61.3.2 | Tested |
| Prometheus | 2.53.x | — | Bundled |
| Grafana | 11.x | — | Bundled |
| AlertManager | 0.27.x | — | Bundled |
| Loki | 3.1.x | chart 6.6.4 | Tested |
| Tempo | 2.5.0 | chart 1.10.3 | Tested |
| OTel Collector | 0.102.1 | 0.102.1 | Tested |
| cert-manager | 1.15.1 | 1.15.1 | Tested |
| Kyverno | 3.2.6 | 3.2.6 | Tested |
| External Secrets | 0.10.0 | 0.10.0 | Tested |
| NGINX Ingress | 1.11.1 | 4.10.1 | Tested |
| traefik/whoami | v1.10.3 | — | Tested |

## macOS Compatibility

| macOS Version | Docker Desktop | Apple Silicon | Intel |
|---------------|---------------|---------------|-------|
| Sonoma 14.x | 4.30+ | ✓ | ✓ |
| Ventura 13.x | 4.28+ | ✓ | ✓ |
| Monterey 12.x | 4.25+ | ✓ | ✓ |

## Known Version Constraints

### Cilium + k3s 1.30

- `--disable-kube-proxy` must be passed to k3s at cluster creation time (before Cilium installs)
- If Cilium is installed before k3s starts with `--disable-kube-proxy`, pods may lose connectivity
- The `nodeinit.enabled=true` Helm value is required for Docker Desktop compatibility

### Gateway API CRDs

- Must use **standard-install.yaml** (not experimental) for stable APIVersions
- v1.1.0 introduces `BackendTLSPolicy` and `GRPCRoute` in stable channel
- Cilium 1.15.x implements Gateway API v1.1.0 controller spec

### Loki v6.x

- The chart structure changed significantly in v6 (unified chart)
- `deploymentMode: SingleBinary` replaces the old `singleBinary.*` nesting
- Schema must be `v13` with `tsdb` store for Loki 3.x

### kube-prometheus-stack v61.x

- Requires Kubernetes 1.25+ for PSS (Pod Security Standards)
- `crds.enabled: true` no longer exists — CRDs are always installed
- Grafana 11.x has breaking changes in dashboard JSON format (still compatible with Loki/Tempo datasource links)

## Linux Compatibility

Tested on Ubuntu 22.04 LTS with:
- Docker Engine 26.x (not Docker Desktop)
- Additional step required: mount BPF filesystem

```bash
# On Linux hosts:
mount bpffs /sys/fs/bpf -t bpf
mount --make-shared /sys/fs/bpf

# Or add to /etc/fstab:
none /sys/fs/bpf bpf defaults 0 0
```

## Version Update Process

When updating a component version:

1. Update `versions.env` with the new version
2. Test install from scratch: `bash bootstrap/reset.sh`
3. Run all tests: `make test-all`
4. Update this document with test results
5. Commit with message: `chore: update <component> to vX.Y.Z`

## Helm Repository Checksums

Chart versions are pinned but Helm repos don't enforce checksums. To verify chart integrity:

```bash
helm pull cilium/cilium --version 1.15.6 --verify 2>/dev/null || \
  helm pull cilium/cilium --version 1.15.6

# Extract and inspect
tar -xzf cilium-1.15.6.tgz
cat cilium/Chart.yaml
```
