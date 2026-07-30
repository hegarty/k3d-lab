# Observability

## Stack Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    Grafana (dashboards)                        │
│  Datasources: Prometheus | Loki | Tempo                       │
└─────────────┬──────────────┬──────────────┬──────────────────┘
              │              │              │
              ▼              ▼              ▼
        Prometheus         Loki          Tempo
        (metrics)          (logs)       (traces)
              ▲              ▲              ▲
              │              │              │
        ┌─────┴──────────────┴──────────────┴──────┐
        │         OTel Collector (DaemonSet)         │
        │   receivers: otlp, kubeletstats, hostmetrics│
        └──────────────────┬───────────────────────-─┘
                           │ OTLP
                           ▼
                  Application Pods
                  (OTLP SDK instrumented)
```

## Components

### Prometheus (kube-prometheus-stack)

- **Chart:** `prometheus-community/kube-prometheus-stack` v61.3.2
- **Namespace:** `observability`
- **Retention:** 7 days, 5GB
- **Components:** Prometheus, AlertManager, Grafana, Prometheus Operator, kube-state-metrics, node-exporter

**Access:**
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
open http://localhost:9090
```

**Auto-scrape targets:**
- All ServiceMonitors and PodMonitors in any namespace
- Cilium agent metrics (port 9962)
- Cilium operator metrics (port 9963)
- kube-state-metrics (pod/deployment/node/PVC status)
- node-exporter (CPU, memory, disk, network)

**Adding custom metrics:**

Create a ServiceMonitor:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: my-namespace
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
    - port: metrics
      interval: 30s
```

### Grafana

- **Chart:** bundled with kube-prometheus-stack
- **Default credentials:** admin / prom-operator
- **Datasources:** Prometheus, Loki, Tempo (pre-configured)

**Access:**
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
open http://localhost:3000
```

**Pre-installed dashboards:**
- Kubernetes cluster overview
- Node metrics
- Pod metrics
- Cilium / Hubble metrics
- Loki log explorer
- Tempo trace explorer

**Adding dashboards:**
Place a dashboard JSON file in a ConfigMap with label `grafana_dashboard: "1"`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |
    { ... Grafana dashboard JSON ... }
```

### Loki

- **Chart:** `grafana/loki` v6.6.4
- **Mode:** Single binary (monolithic)
- **Storage:** Local filesystem (PVC, `local-path`)
- **Log collectors:** Promtail DaemonSet

**Access:**
```bash
kubectl port-forward -n observability svc/loki-gateway 3100:80
# Query labels
curl http://localhost:3100/loki/api/v1/labels

# In Grafana: Explore → Loki datasource
```

**Querying logs with LogQL:**
```logql
# All logs from hello-world namespace
{namespace="hello-world"}

# Error logs from specific pod
{namespace="hello-world", pod=~"hello-world-.*"} |= "error"

# JSON parsing
{namespace="hello-world"} | json | level="error"

# Rate of error logs
sum(rate({namespace="hello-world"} |= "error" [5m])) by (pod)
```

### Tempo

- **Chart:** `grafana/tempo` v1.10.3
- **Mode:** Monolithic
- **Receivers:** OTLP (gRPC:4317, HTTP:4318), Zipkin (9411), Jaeger (14268)
- **Storage:** Local filesystem

**Access:**
```bash
kubectl port-forward -n observability svc/tempo 3200:3100
# Check ready
curl http://localhost:3200/ready
```

**TraceQL queries (in Grafana Explore):**
```traceql
# All traces for a service
{resource.service.name="hello-world"}

# Slow traces
{resource.service.name="hello-world" && duration > 500ms}

# Errors
{status=error}

# Traces with specific span attribute
{span.http.method="POST" && span.http.status_code=500}
```

**Sending traces from your app:**
```yaml
# Environment variables for OTLP SDK
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-gateway.observability.svc.cluster.local:4317"
  - name: OTEL_SERVICE_NAME
    value: "my-service"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment=local,service.version=1.0.0"
```

### OpenTelemetry Collector

- **Chart:** `open-telemetry/opentelemetry-collector` v0.102.1
- **Mode:** DaemonSet (one per node) + Deployment (gateway aggregator)

**Pipelines:**

| Pipeline | Receivers | Exporters |
|----------|-----------|-----------|
| traces | OTLP | Tempo |
| metrics | OTLP, Prometheus, kubeletstats | Prometheus remote write |
| logs | OTLP, k8s_events | Loki |

**Enrichment:** k8sattributes processor adds:
- `k8s.pod.name`
- `k8s.deployment.name`
- `k8s.namespace.name`
- `k8s.node.name`
- Pod labels (`app`, `version`)

## Installing the Stack

```bash
# Full observability stack
INSTALL_OBSERVABILITY=true ./bootstrap/install.sh

# Individual components
bash observability/kube-prometheus-stack/install.sh
bash observability/loki/install.sh
bash observability/tempo/install.sh
bash observability/opentelemetry/install.sh
```

## Enabling ServiceMonitors for Other Components

Many Helm charts support a `serviceMonitor.enabled` value. Once kube-prometheus-stack is installed, re-install/upgrade with:

```bash
# Cilium with ServiceMonitor
helm upgrade cilium cilium/cilium -n kube-system \
  --reuse-values \
  --set prometheus.serviceMonitor.enabled=true

# Kyverno
helm upgrade kyverno kyverno/kyverno -n kyverno \
  --reuse-values \
  --set serviceMonitor.enabled=true
```

## Alerts

AlertManager is configured and reachable:
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093
open http://localhost:9093
```

Default alert rules include:
- Node memory/CPU pressure
- Pod crash loops
- PVC near capacity
- Prometheus target down

## Correlating Signals

Grafana's exemplars and datasource linking enable correlation:

1. **Traces → Logs:** In Grafana Explore, open a trace → click "Logs for this span" → jumps to Loki with matching time range and trace ID filter
2. **Metrics → Traces:** In Grafana dashboards, click a metric spike → "Explore traces" → shows Tempo traces from that time window
3. **Logs → Traces:** In Loki queries, filter by `traceID` extracted from log lines
