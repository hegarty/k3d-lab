# Observability — k3d-lab

This document covers the five observability services running in the cluster, how to access each one, and how to instrument your own applications to send data to them.

> **Prerequisites:** Run `make observability-install` before using anything in this guide.
> All services live in the `observability` namespace.

---

## Architecture

```
Your application
       │
       ▼
OpenTelemetry Collector  ◄── Promtail (container logs from /var/log/containers)
       │
       ├──► Tempo        (traces)      ──► Grafana
       ├──► Prometheus   (metrics)     ──► Grafana
       └──► Loki         (logs)        ──► Grafana

Cilium / Hubble ──────────────────────► Prometheus ──► Grafana
```

**Data flow:**
- **Traces** — your app sends OTLP to the OTel Collector → forwarded to Tempo → visualised in Grafana
- **Metrics** — Prometheus scrapes ServiceMonitors/PodMonitors + Cilium/Hubble via static configs → visualised in Grafana
- **Logs** — Promtail reads pod container logs from disk → pushes to Loki → queryable in Grafana
- **Network flows** — Hubble (built into Cilium) exposes flow metrics → scraped by Prometheus → visualised in Grafana

---

## Quick Access

All services require `kubectl port-forward` on macOS (Docker network is not routable from the host).

```bash
# Grafana  —  http://localhost:3000  (admin / prom-operator)
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80

# Prometheus  —  http://localhost:9090
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# Loki  —  http://localhost:3100  (query API)
kubectl port-forward -n observability svc/loki-gateway 3100:80

# Tempo  —  http://localhost:3200  (query API, used by Grafana)
kubectl port-forward -n observability pod/tempo-0 3200:3100

# Hubble UI  —  http://localhost:12000  (real-time network flows)
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
```

Makefile shortcuts for the most common ones:

```bash
make grafana      # → http://localhost:3000
make prometheus   # → http://localhost:9090
make hubble-ui    # → http://localhost:12000
```

---

## Prometheus

Prometheus scrapes metrics from across the cluster on a 30-second interval. It is pre-configured to discover targets via ServiceMonitors and PodMonitors in all namespaces.

### What is already scraped

| Job | Source | Port |
|---|---|---|
| Kubernetes nodes | kubelet | 10250 |
| Kubernetes pods | cAdvisor | 10250 |
| kube-state-metrics | cluster object state | 8080 |
| node-exporter | host CPU/memory/disk | 9100 |
| Prometheus itself | internal metrics | 9090 |
| Grafana | internal metrics | 3000 |
| Loki | internal metrics | via ServiceMonitor |
| Tempo | internal metrics | via ServiceMonitor |
| cilium-agent | eBPF/policy metrics | 9962 |
| cilium-operator | operator metrics | 9963 |
| hubble | network flow metrics | 9965 |

### Expose metrics from your application

**Option 1 — ServiceMonitor (recommended)**

If your app exposes a Prometheus `/metrics` endpoint, create a ServiceMonitor. Prometheus will auto-discover it because `serviceMonitorSelectorNilUsesHelmValues: false` is set (scrapes all namespaces).

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: my-app-namespace
spec:
  selector:
    matchLabels:
      app: my-app          # must match your Service's labels
  endpoints:
    - port: metrics        # must match the named port on your Service
      interval: 30s
      path: /metrics
```

Your Service must expose a named port:
```yaml
ports:
  - name: metrics
    port: 9090
    protocol: TCP
```

**Option 2 — PodMonitor**

Use a PodMonitor when you want to scrape pods directly without a Service in front:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: my-app
  namespace: my-app-namespace
spec:
  selector:
    matchLabels:
      app: my-app
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
```

**Option 3 — Prometheus annotations (legacy, not recommended)**

```yaml
# Pod annotations — Prometheus will scrape if a scrape config looks for them
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"
  prometheus.io/path: "/metrics"
```

Note: the kube-prometheus-stack does not include a scrape config for annotations by default. Use ServiceMonitor instead.

### Verify a target is being scraped

```bash
# Open Prometheus, go to Status → Targets
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/targets

# Or query directly
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[].labels.job' | sort -u
```

### Useful PromQL queries

```promql
# All scrape targets that are up
up

# CPU usage per pod
sum(rate(container_cpu_usage_seconds_total{namespace!=""}[5m])) by (pod, namespace)

# Memory usage per pod
sum(container_memory_working_set_bytes{container!=""}) by (pod, namespace)

# Hubble: HTTP request rate by destination
sum(rate(hubble_http_requests_total[5m])) by (destination)

# Hubble: dropped packets
sum(rate(hubble_drop_total[5m])) by (reason, direction)

# Cilium: policy enforcement verdicts
sum(rate(cilium_policy_verdict_total[5m])) by (direction, reason)
```

---

## Grafana

Grafana is the single UI for all three signal types (metrics, logs, traces). It is pre-configured with three datasources on startup.

### Access

```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000
# Credentials: admin / prom-operator
```

### Pre-configured datasources

| Name | UID | Type | Endpoint |
|---|---|---|---|
| Prometheus | (default) | Prometheus | kube-prometheus-stack-prometheus:9090 |
| Loki | `loki` | Loki | loki-gateway:80 |
| Tempo | `tempo` | Tempo | tempo:3100 |

### Cross-datasource linking

The datasources are wired for navigation between signal types:

- **Tempo → Loki:** From a trace in Tempo, click "Logs for this trace" to jump directly to the correlated log lines in Loki (uses `tracesToLogsV2`)
- **Loki → Tempo:** Log lines containing `"traceID":"<id>"` have a clickable link that opens the trace in Tempo (uses `derivedFields`)
- **Tempo → Prometheus:** Service map and span metrics link to Prometheus queries (uses `tracesToMetrics` and `serviceMap`)

For cross-datasource links to work, your application logs must include the trace ID in JSON format:
```json
{"level":"info","traceID":"4bf92f3577b34da6a3ce929d0e0e4736","msg":"request handled"}
```

### Pre-loaded dashboards

Grafana's sidecar automatically imports dashboards from ConfigMaps across all namespaces. The following are loaded automatically:

- Kubernetes cluster overview (from kube-prometheus-stack)
- Node exporter full (from kube-prometheus-stack)
- Loki dashboards (from Loki chart)

To add your own dashboard as code:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: my-app-namespace
  labels:
    grafana_dashboard: "1"    # this label triggers the sidecar to import it
data:
  my-dashboard.json: |
    { ... grafana dashboard JSON ... }
```

### Useful LogQL queries in Grafana Explore

```logql
# All logs from a namespace
{namespace="hello-world"}

# Logs from a specific pod label
{app="hello-world"}

# Filter by log level
{namespace="hello-world"} |= "error"

# Parse JSON logs and filter on a field
{namespace="my-app"} | json | level="error"

# Rate of log lines per minute
rate({namespace="hello-world"}[1m])
```

---

## Hubble

Hubble is Cilium's built-in network observability layer. It provides real-time visibility into all network flows between pods without requiring any application changes.

### Hubble UI

```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# open http://localhost:12000
```

Or:
```bash
make hubble-ui
```

The UI shows a real-time directed graph of pod-to-pod network flows. Select a namespace from the dropdown to see traffic in that namespace. Flows are colour-coded: green (allowed), red (dropped/denied).

### Hubble metrics in Prometheus

Hubble flow metrics are scraped on port 9965 of each Cilium agent pod. Available in Prometheus under the `hubble` job:

| Metric | Description |
|---|---|
| `hubble_drop_total` | Dropped packets by reason and direction |
| `hubble_http_requests_total` | HTTP requests by method, protocol, reporter |
| `hubble_http_request_duration_seconds` | HTTP request latency histogram |
| `hubble_tcp_flags_total` | TCP flag counts (SYN, FIN, RST, etc.) |
| `hubble_flows_processed_total` | Total flows by type (L3/L4/L7) |
| `hubble_dns_queries_total` | DNS query counts |
| `hubble_dns_responses_total` | DNS response counts by rcode |

Example queries:

```promql
# Pods generating the most dropped traffic
topk(10, sum(rate(hubble_drop_total[5m])) by (source))

# HTTP error rate between services
sum(rate(hubble_http_requests_total{http_status=~"5.."}[5m])) by (source, destination)

# DNS NXDOMAIN rate (misconfigured service discovery)
sum(rate(hubble_dns_responses_total{rcode="Non-Existent Domain"}[5m])) by (source)
```

### Hubble CLI (if cilium CLI is installed)

```bash
# Watch live flows
cilium hubble observe --follow

# Watch flows for a specific pod
cilium hubble observe --pod hello-world/hello-world-<hash> --follow

# Watch only dropped flows
cilium hubble observe --verdict DROPPED --follow
```

---

## Loki

Loki stores and indexes logs. Unlike Elasticsearch, Loki does not index log content — it indexes labels (namespace, pod, container) and stores the raw log text compressed. This makes it significantly cheaper to run.

### How logs get into Loki

**Container logs (automatic):** Promtail runs as a DaemonSet and reads all container logs from `/var/log/containers/*.log` on each node. Any pod writing to stdout/stderr is automatically captured. No application changes needed.

**Kubernetes events:** The OTel Collector captures Kubernetes events (`kubectl get events`) and ships them to Loki as structured log entries.

**Application direct push (optional):** Applications can push logs directly to Loki using the HTTP API or an OpenTelemetry SDK.

### Loki labels

Promtail automatically adds these labels to every log stream:

| Label | Value |
|---|---|
| `namespace` | Kubernetes namespace |
| `pod` | Pod name |
| `container` | Container name |
| `node_name` | Node the pod runs on |
| `app` | Value of the `app` label on the pod |

### Query logs

```bash
# Port-forward Loki gateway
kubectl port-forward -n observability svc/loki-gateway 3100:80

# Query recent logs from hello-world
curl -s "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="hello-world"}' \
  --data-urlencode 'limit=20' | jq '.data.result[].values[][1]'
```

In Grafana Explore (select the Loki datasource):

```logql
# All logs from a namespace
{namespace="hello-world"}

# Logs from a container
{namespace="hello-world", container="hello-world"}

# Filter by text
{namespace="hello-world"} |= "GET /health"

# Parse JSON and filter by field
{namespace="my-app"} | json | level="error" | msg != ""

# Count errors per minute
sum(rate({namespace="my-app"} |= "error" [1m]))
```

### Push logs from your application directly

If you want your app to push structured logs directly (in addition to stdout capture):

```bash
# Push a test log entry
curl -s -X POST http://localhost:3100/loki/api/v1/push \
  -H "Content-Type: application/json" \
  --data '{
    "streams": [{
      "stream": {"app": "my-app", "namespace": "default", "level": "info"},
      "values": [["'"$(date +%s)000000000"'", "{\"msg\": \"hello from my app\", \"traceID\": \"abc123\"}"]]
    }]
  }'
```

From inside the cluster, use the gateway endpoint:
```
http://loki-gateway.observability.svc.cluster.local:80/loki/api/v1/push
```

---

## Tempo

Tempo stores distributed traces. It accepts spans in OTLP format (and also Jaeger, Zipkin). Traces are queried through Grafana using TraceQL.

### Endpoints

| Protocol | Endpoint (in-cluster) | Port |
|---|---|---|
| OTLP gRPC | `tempo.observability.svc.cluster.local` | 4317 |
| OTLP HTTP | `tempo.observability.svc.cluster.local` | 4318 |
| Jaeger gRPC | `tempo.observability.svc.cluster.local` | 14250 |
| Jaeger HTTP | `tempo.observability.svc.cluster.local` | 14268 |
| Zipkin | `tempo.observability.svc.cluster.local` | 9411 |

> **Prefer sending to the OTel Collector, not directly to Tempo.** The collector batches, enriches with pod metadata, and handles retries. Use `otel-collector.observability.svc.cluster.local:4317`.

### Instrument your application

**Python (opentelemetry-sdk)**

```bash
pip install opentelemetry-sdk opentelemetry-exporter-otlp
```

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

provider = TracerProvider()
exporter = OTLPSpanExporter(
    endpoint="http://otel-collector.observability.svc.cluster.local:4317",
    insecure=True,
)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)

with tracer.start_as_current_span("my-operation") as span:
    span.set_attribute("user.id", "42")
    # ... your code
```

**Go (opentelemetry-go)**

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

exporter, _ := otlptracegrpc.New(ctx,
    otlptracegrpc.WithEndpoint("otel-collector.observability.svc.cluster.local:4317"),
    otlptracegrpc.WithInsecure(),
)
tp := sdktrace.NewTracerProvider(
    sdktrace.WithBatcher(exporter),
    sdktrace.WithResource(resource.NewWithAttributes(
        semconv.SchemaURL,
        semconv.ServiceNameKey.String("my-service"),
    )),
)
otel.SetTracerProvider(tp)
```

**Node.js (@opentelemetry/sdk-node)**

```javascript
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: 'http://otel-collector.observability.svc.cluster.local:4317',
  }),
});
sdk.start();
```

### Send a test trace

```bash
# Port-forward Tempo OTLP HTTP
kubectl port-forward -n observability pod/tempo-0 4318:4318

# Push a minimal OTLP trace
curl -s -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{
    "resourceSpans": [{
      "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "test-service"}}]},
      "scopeSpans": [{
        "spans": [{
          "traceId": "5b8aa5a2d2c872e8321cf37308d69df2",
          "spanId": "051581bf3cb55c13",
          "name": "test-operation",
          "startTimeUnixNano": "'"$(date +%s%N)"'",
          "endTimeUnixNano": "'"$(( $(date +%s%N) + 1000000 ))"'",
          "kind": 1,
          "status": {}
        }]
      }]
    }]
  }'
```

Then find it in Grafana → Explore → Tempo → Search → Service Name: `test-service`.

### Query traces in Grafana

Open Grafana → Explore → select **Tempo** datasource.

**Search tab:** filter by service name, span name, duration, tags.

**TraceQL tab:** query language for traces:

```
# Find all traces from a service
{ resource.service.name = "my-service" }

# Find slow requests (>500ms)
{ resource.service.name = "my-service" && duration > 500ms }

# Find traces with errors
{ status = error }

# Find specific HTTP routes
{ span.http.route = "/api/users" && span.http.status_code >= 500 }
```

---

## OpenTelemetry Collector

The OTel Collector runs as a DaemonSet (one pod per node) and as a standalone gateway Deployment. It is the recommended ingestion point for application telemetry.

### Endpoints (in-cluster)

| Signal | Protocol | Endpoint | Port |
|---|---|---|---|
| Traces | OTLP gRPC | `otel-collector.observability.svc.cluster.local` | 4317 |
| Traces | OTLP HTTP | `otel-collector.observability.svc.cluster.local` | 4318 |
| Metrics | OTLP gRPC | `otel-collector.observability.svc.cluster.local` | 4317 |
| Logs | OTLP gRPC | `otel-collector.observability.svc.cluster.local` | 4317 |

### What the collector does automatically

The DaemonSet collector enriches every span and metric with Kubernetes metadata before forwarding:

| Attribute added | Source |
|---|---|
| `k8s.pod.name` | Downward API |
| `k8s.namespace.name` | Downward API |
| `k8s.deployment.name` | k8s API |
| `k8s.node.name` | Downward API |
| `app`, `version` | Pod labels |
| Host/node identity | resourcedetection processor |

This enrichment means you do not need to add these attributes manually in your application SDK.

### Pipelines

| Pipeline | Receivers | Exporters |
|---|---|---|
| traces | OTLP | Tempo |
| metrics | OTLP, kubeletstats, hostmetrics, prometheus | Prometheus remote write |
| logs | OTLP, k8s_events | Loki |

### Check collector health

```bash
# Collector metrics (8888 is the self-metrics port)
kubectl port-forward -n observability \
  daemonset/otel-collector-opentelemetry-collector 8888:8888
curl http://localhost:8888/metrics | grep otelcol_receiver_accepted
```

---

## Verified test suite

```bash
make test-observability
```

Expected: **10/10 tests passing**.

| Test | What it checks |
|---|---|
| Prometheus pod running | 1+ pods in Running phase |
| Prometheus API ready | `/-/ready` returns ready |
| Prometheus has data | `up` metric returns ≥1 series |
| Grafana pod running | 1+ pods in Running phase |
| Grafana API healthy | `/api/health` returns ok |
| Loki pod running | 1+ pods in Running phase |
| Loki ready | `/ready` on pod/loki-0:3100 returns ready |
| Tempo pod running | 1+ pods in Running phase |
| Tempo ready | `/ready` on svc/tempo:3100 returns ready |
| OTel Collector running | 1+ DaemonSet pods in Running phase |

---

## Troubleshooting

### Grafana cannot connect to Loki

Check the datasource URL matches the running service:

```bash
kubectl get svc -n observability | grep loki
# Should show: loki-gateway (port 80)
```

Expected URL in Grafana: `http://loki-gateway.observability.svc.cluster.local:80`

### Grafana cannot connect to Tempo

Check the Tempo service and port:

```bash
kubectl get svc -n observability tempo
# Should show port 3100/TCP
```

Expected URL in Grafana: `http://tempo.observability.svc.cluster.local:3100`

> **Note:** Do not use `tempo-query-frontend` — that service only exists in distributed (microservices) Tempo mode. This cluster runs Tempo in monolithic mode, service name is `tempo`.

### No metrics from my application

1. Verify your pod exposes `/metrics` and returns valid Prometheus format
2. Verify your ServiceMonitor's `selector` matches your Service's labels
3. Check Prometheus targets: `http://localhost:9090/targets`
4. Check Prometheus logs: `kubectl logs -n observability -l app.kubernetes.io/name=prometheus --tail=20`

### No traces appearing in Tempo

1. Verify your application is sending to the correct endpoint
2. Check OTel Collector is receiving: look for `otelcol_receiver_accepted_spans` metric
3. Check OTel Collector logs: `kubectl logs -n observability -l app.kubernetes.io/name=opentelemetry-collector --tail=30`
4. Send a test trace manually (see "Send a test trace" section above)

### Loki shows no logs

1. Check Promtail DaemonSet is running: `kubectl get ds -n observability promtail`
2. Check Promtail logs: `kubectl logs -n observability -l app.kubernetes.io/name=promtail --tail=20`
3. Verify Loki is ready: `kubectl port-forward -n observability pod/loki-0 3100:3100 && curl http://localhost:3100/ready`
