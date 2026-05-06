# Log Aggregation — Shipping Pino Logs to Loki

The application emits structured JSON logs via **pino** (configured in
`app/src/lib/logger.js`).  This guide shows how to ship those logs to
**Grafana Loki** using either **Promtail** or **Vector**.

---

## Option A — Promtail

Promtail is Loki's purpose-built log collector, tightly integrated with
Kubernetes pod discovery.

### How it works

1. Promtail runs as a DaemonSet on every node.
2. It tails `/var/log/pods/**/*.log` and applies relabelling to attach pod
   labels (app, namespace, container) as Loki stream labels.
3. The JSON log lines are forwarded to Loki unchanged — Loki's LogQL can then
   parse individual JSON fields at query time using `| json` or `| logfmt`.

### Sample `promtail-config.yaml`

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Only collect pods in namespaces we care about
      - source_labels: [__meta_kubernetes_namespace]
        action: keep
        regex: production|staging

      # Expose useful stream labels
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: app
      - source_labels: [__meta_kubernetes_pod_container_name]
        target_label: container

    pipeline_stages:
      # Parse pino JSON — extracts level, msg, requestId, etc. as structured fields
      - json:
          expressions:
            level: level
            msg: msg
            requestId: requestId
            statusCode: res.statusCode
            responseTime: responseTime

      # Map pino numeric level to a human-readable Loki label
      - template:
          source: level
          template: |
            {{ if eq .Value "10" }}trace
            {{ else if eq .Value "20" }}debug
            {{ else if eq .Value "30" }}info
            {{ else if eq .Value "40" }}warn
            {{ else if eq .Value "50" }}error
            {{ else if eq .Value "60" }}fatal
            {{ else }}unknown{{ end }}
      - labels:
          level:

      # Set the log timestamp from pino's `time` field (epoch ms)
      - timestamp:
          source: time
          format: UnixMs
```

### Useful LogQL queries

```logql
# All error logs for my-app in production
{app="my-app", namespace="production", level="error"} | json

# Slow requests (responseTime > 500 ms)
{app="my-app", namespace="production"} | json | responseTime > 500

# Tail logs for a specific requestId
{app="my-app"} | json | requestId = "abc-123"
```

---

## Option B — Vector

Vector is a high-performance, topology-agnostic data pipeline.  It suits
environments that already use Vector for metrics or want a single agent for
logs + metrics.

### How it works

1. Vector runs as a DaemonSet (or as a sidecar) and tails Kubernetes pod logs.
2. It parses JSON in-process via the `parse_json` VRL function.
3. Transformed events are pushed to Loki's HTTP push endpoint.

### Sample `vector.yaml` (agent config)

```yaml
# vector.yaml — Kubernetes DaemonSet agent config

sources:
  kubernetes_logs:
    type: kubernetes_logs
    namespace_labels_as_metadata: true
    # Only scrape pods with this label
    extra_label_selector: "app=my-app"

transforms:
  parse_pino:
    type: remap
    inputs: ["kubernetes_logs"]
    source: |
      # Parse the JSON log line emitted by pino
      parsed, err = parse_json(.message)
      if err == null {
        .level       = to_string(parsed.level) ?? "unknown"
        .msg         = parsed.msg
        .requestId   = parsed.requestId
        .statusCode  = parsed.res.statusCode
        .responseTime = parsed.responseTime
        # Map pino numeric level to label string
        .level_name  = if .level == "50" { "error" }
                       else if .level == "40" { "warn" }
                       else if .level == "30" { "info" }
                       else { "debug" }
      }

  add_labels:
    type: remap
    inputs: ["parse_pino"]
    source: |
      .loki_labels = {
        "app":       .kubernetes.pod_labels.app,
        "namespace": .kubernetes.pod_namespace,
        "container": .kubernetes.container_name,
        "level":     .level_name,
      }

sinks:
  loki:
    type: loki
    inputs: ["add_labels"]
    endpoint: "http://loki:3100"
    labels:
      app:       "{{ loki_labels.app }}"
      namespace: "{{ loki_labels.namespace }}"
      container: "{{ loki_labels.container }}"
      level:     "{{ loki_labels.level }}"
    encoding:
      codec: json
    # Remove intermediate processing fields before shipping
    remove_label_fields: true
```

---

## Comparison

| Concern | Promtail | Vector |
|---------|----------|--------|
| Designed for | Loki only | Multi-destination |
| Config complexity | Low | Medium |
| Throughput | Good | Excellent |
| VRL transformation | No | Yes (powerful) |
| Metrics shipping | No | Yes (side-by-side) |

---

## References

- [Promtail documentation](https://grafana.com/docs/loki/latest/clients/promtail/)
- [Vector Loki sink](https://vector.dev/docs/reference/configuration/sinks/loki/)
- [Grafana Loki LogQL](https://grafana.com/docs/loki/latest/query/)
- `app/src/lib/logger.js` — pino logger configuration
