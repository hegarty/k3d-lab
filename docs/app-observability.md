# Application Observability Standards

> **Read this before building a new service for this environment.**
>
> This document defines the logging, metrics, and tracing standards for every application deployed to this cluster. Following these standards means your service will appear automatically in Grafana dashboards, Tempo trace explorer, and Loki log queries — with no additional platform configuration required.
>
> For platform internals (what's installed, how to access each service), see [OBSERVABILITY.md](../OBSERVABILITY.md).

---

## What you get automatically

Before writing a single line of SDK code, your service already has:

| Signal | What happens automatically | Where it appears |
|---|---|---|
| **Logs** | Promtail reads all pod stdout/stderr from the node | Grafana → Explore → Loki |
| **Network flows** | Hubble captures every TCP/HTTP connection to/from your pod | Grafana → Hubble metrics, Hubble UI |
| **Pod metrics** | kube-state-metrics exports pod lifecycle metrics (restarts, readiness, resource usage) | Grafana → Explore → Prometheus |

What you need to **add** yourself:

| Signal | What to add | Where it appears |
|---|---|---|
| **Traces** | Instrument with an OTLP SDK, set 2 env vars | Grafana → Explore → Tempo |
| **Custom metrics** | Expose `/metrics` endpoint, add ServiceMonitor | Grafana → Explore → Prometheus |
| **Structured logs** | Format stdout as JSON with standard fields | Grafana → Loki (enriched, filterable) |

---

## 1. Required Kubernetes labels

Every Deployment, StatefulSet, and DaemonSet must include these labels on **both** the resource metadata and the pod template metadata:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: my-service        # kebab-case service name
    app.kubernetes.io/version: "1.2.3"        # semver, matches image tag
    app.kubernetes.io/component: backend       # backend | frontend | worker | cache
    app.kubernetes.io/part-of: my-app         # the product/system this belongs to
```

**Why:** These labels are the primary selectors used by Prometheus ServiceMonitors, Kyverno policy reports, and Hubble flow filtering. Without them, cross-service correlation in Grafana is difficult.

---

## 2. Tracing

### OTLP endpoint

All traces must be sent to the OTel gateway collector running in the cluster:

| Protocol | Endpoint | Use when |
|---|---|---|
| gRPC (recommended) | `http://otel-gateway.observability.svc.cluster.local:4317` | Go, Java, Python, .NET |
| HTTP | `http://otel-gateway.observability.svc.cluster.local:4318` | Browser JS, environments where gRPC is unavailable |

The gateway handles batching, memory limiting, and forwarding to Tempo. Your app sends fire-and-forget.

### Required environment variables

Add these to every container spec:

```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: my-service                          # must match app.kubernetes.io/name label
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://otel-gateway.observability.svc.cluster.local:4317
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: grpc
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "service.version=$(APP_VERSION),deployment.environment=k3d-lab"
```

> `OTEL_SERVICE_NAME` drives the service name that appears in Tempo and all trace queries. Use the same value as `app.kubernetes.io/name`.

### SDK setup by language

**Go**

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer(ctx context.Context) (*trace.TracerProvider, error) {
    exporter, err := otlptracegrpc.New(ctx)  // reads OTEL_EXPORTER_OTLP_ENDPOINT from env
    if err != nil {
        return nil, err
    }
    tp := trace.NewTracerProvider(
        trace.WithBatcher(exporter),
        trace.WithSampler(trace.AlwaysSample()),  // adjust for production
    )
    otel.SetTracerProvider(tp)
    return tp, nil
}
```

**Python**

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

provider = TracerProvider()
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter())  # reads OTEL_EXPORTER_OTLP_ENDPOINT from env
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)
```

**Node.js**

```javascript
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter(),  // reads OTEL_EXPORTER_OTLP_ENDPOINT from env
});
sdk.start();
```

### Viewing traces in Grafana

```
Grafana → Explore → Select datasource: Tempo
Search: service.name = my-service
```

Or jump directly from a Loki log line that contains a `traceID` field — the derived field link opens the trace automatically.

---

## 3. Metrics

### Automatic collection (annotation-based)

For simple use cases, add these annotations to your pod template and Prometheus will scrape your `/metrics` endpoint:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"     # port your /metrics endpoint is on
    prometheus.io/path: "/metrics" # default, omit if using /metrics
```

### Recommended: ServiceMonitor

For production services, use a `ServiceMonitor` instead of annotations. It gives you label-based filtering, custom scrape intervals, and is the Prometheus Operator standard:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-service
  namespace: my-namespace
  labels:
    app.kubernetes.io/name: my-service
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: my-service
  endpoints:
    - port: http          # must match a named port in your Service
      path: /metrics
      interval: 30s
```

**Important:** The ServiceMonitor must be in the same namespace as your Service, or you must configure `namespaceSelector`. The kube-prometheus-stack in this cluster is configured to discover ServiceMonitors across all namespaces.

### Useful PromQL queries for your service

```promql
# Request rate (requires http_requests_total counter)
rate(http_requests_total{service="my-service"}[5m])

# Error rate
rate(http_requests_total{service="my-service", status=~"5.."}[5m])

# P99 latency (requires http_request_duration_seconds histogram)
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{service="my-service"}[5m]))

# Memory usage
container_memory_working_set_bytes{pod=~"my-service-.*"}

# CPU usage
rate(container_cpu_usage_seconds_total{pod=~"my-service-.*"}[5m])
```

---

## 4. Logs

### Automatic collection

Promtail runs as a DaemonSet and collects **all pod stdout/stderr** automatically. No configuration needed. Logs are queryable immediately in Grafana → Explore → Loki.

Default Loki label set attached to every log line:

| Label | Value | Source |
|---|---|---|
| `namespace` | e.g. `my-namespace` | pod metadata |
| `pod` | e.g. `my-service-7d9f-xyz` | pod metadata |
| `container` | e.g. `my-service` | container name |
| `app` | e.g. `my-service` | pod label `app` |
| `node_name` | e.g. `k3d-k3d-lab-server-0` | node name |

### Structured logging (strongly recommended)

Write logs as **JSON to stdout**. Promtail will parse JSON fields and make them filterable in Loki.

Minimum required fields:

```json
{
  "timestamp": "2026-08-19T10:00:00.000Z",
  "level": "info",
  "message": "request completed",
  "service": "my-service",
  "trace_id": "abc123def456",
  "span_id": "789xyz"
}
```

The `trace_id` field is critical — it enables Grafana to link from a log line directly to the corresponding trace in Tempo (via the derived field configured on the Loki datasource).

**Go (slog)**

```go
import "log/slog"

logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
logger.Info("request completed",
    "trace_id", span.SpanContext().TraceID().String(),
    "span_id",  span.SpanContext().SpanID().String(),
    "method",   r.Method,
    "path",     r.URL.Path,
    "status",   statusCode,
    "duration_ms", duration.Milliseconds(),
)
```

**Python (structlog)**

```python
import structlog
log = structlog.get_logger()
log.info("request completed",
    trace_id=trace.get_current_span().get_span_context().trace_id,
    method=request.method,
    path=request.path,
    status=response.status_code,
)
```

### LogQL queries for your service

```logql
# All logs from your service
{namespace="my-namespace", app="my-service"}

# Error logs only
{namespace="my-namespace", app="my-service"} | json | level="error"

# Logs for a specific trace
{namespace="my-namespace"} | json | trace_id="abc123def456"

# Log volume rate (useful for alerting)
sum(rate({namespace="my-namespace", app="my-service"}[5m]))
```

---

## 5. Network visibility (automatic)

Cilium Hubble captures every network flow to and from your pod with no instrumentation required.

**Access Hubble UI:**
```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# open http://localhost:12000 — select your namespace from the dropdown
```

**Useful Hubble PromQL queries:**
```promql
# Inbound request rate to your service (by source namespace)
sum by (source_namespace) (
  rate(hubble_flows_processed_total{destination_pod=~"my-service-.*", type="L7"}[5m])
)

# Dropped packets (policy violations)
sum(rate(hubble_drop_total{destination_pod=~"my-service-.*"}[5m]))
```

---

## 6. Reference deployment manifest

Copy this template when starting a new service. Replace all `my-service` / `my-namespace` / `my-app` placeholders.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: my-namespace
  labels:
    app.kubernetes.io/part-of: my-app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
  namespace: my-namespace
  labels:
    app.kubernetes.io/name: my-service
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: my-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: my-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: my-service
        app.kubernetes.io/version: "1.0.0"
        app.kubernetes.io/component: backend
        app.kubernetes.io/part-of: my-app
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: my-service
          image: my-registry/my-service:1.0.0   # never use :latest
          ports:
            - containerPort: 8080
              name: http
          env:
            # --- Observability (required) ---
            - name: OTEL_SERVICE_NAME
              value: my-service
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://otel-gateway.observability.svc.cluster.local:4317
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: grpc
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "deployment.environment=k3d-lab"
            # --- Application config ---
            - name: PORT
              value: "8080"
            - name: LOG_FORMAT
              value: json
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: my-namespace
  labels:
    app.kubernetes.io/name: my-service
spec:
  selector:
    app.kubernetes.io/name: my-service
  ports:
    - name: http
      port: 80
      targetPort: 8080
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-service
  namespace: my-namespace
  labels:
    app.kubernetes.io/name: my-service
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: my-service
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

---

## 7. New service checklist

Before deploying a new service, confirm:

### Kubernetes
- [ ] `app.kubernetes.io/name` label on Deployment and pod template
- [ ] `app.kubernetes.io/version` label matches image tag (no `:latest`)
- [ ] `app.kubernetes.io/component` and `app.kubernetes.io/part-of` labels set
- [ ] `runAsNonRoot: true` in pod securityContext
- [ ] CPU and memory requests AND limits set
- [ ] `readinessProbe` and `livenessProbe` configured
- [ ] `readOnlyRootFilesystem: true` where possible

### Tracing
- [ ] `OTEL_SERVICE_NAME` env var set (matches `app.kubernetes.io/name`)
- [ ] `OTEL_EXPORTER_OTLP_ENDPOINT` set to `http://otel-gateway.observability.svc.cluster.local:4317`
- [ ] OTel SDK initialised in application code
- [ ] Verify: trace appears in Grafana → Explore → Tempo after first request

### Metrics
- [ ] `/metrics` endpoint exposed (Prometheus format)
- [ ] `prometheus.io/scrape: "true"` annotation OR ServiceMonitor applied
- [ ] Verify: metric appears in Grafana → Explore → Prometheus

### Logs
- [ ] Logging to stdout (not a file)
- [ ] JSON format with `timestamp`, `level`, `message`, `trace_id` fields
- [ ] Verify: logs appear in Grafana → Explore → Loki with `{app="my-service"}`

### Cross-signal linking
- [ ] `trace_id` field present in log output — enables Loki → Tempo jump links
- [ ] Verify: click trace link from a Loki log line in Grafana

---

## 8. Verifying your service in Grafana

```bash
# Open Grafana
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000  —  admin / prom-operator
```

| What to check | Where in Grafana |
|---|---|
| Service is sending traces | Explore → Tempo → Search → `service.name = my-service` |
| Logs are flowing | Explore → Loki → `{namespace="my-namespace", app="my-service"}` |
| Metrics are scraped | Explore → Prometheus → `up{job="my-service"}` |
| Log → Trace link works | Open a log line in Loki, click the Tempo trace link icon |
| Network flows | Hubble UI → select `my-namespace` |

---

## Reference

- **Platform internals** (what's installed, port-forward commands, PromQL/LogQL/TraceQL examples): [OBSERVABILITY.md](../OBSERVABILITY.md)
- **OTel SDK docs**: https://opentelemetry.io/docs/instrumentation/
- **Prometheus client libraries**: https://prometheus.io/docs/instrumenting/clientlibs/
- **LogQL reference**: https://grafana.com/docs/loki/latest/query/
- **TraceQL reference**: https://grafana.com/docs/tempo/latest/traceql/
