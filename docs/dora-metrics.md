# DORA Metrics — Infrastructure & Querying Guide

## The Four DORA Metrics

DORA (DevOps Research and Assessment) metrics measure software delivery performance across four dimensions:

| Metric | What it measures | Elite benchmark |
|--------|-----------------|-----------------|
| **Deployment Frequency** | How often code reaches production | On-demand (multiple/day) |
| **Lead Time for Changes** | Time from first commit to production | < 1 hour |
| **Change Failure Rate** | % of deployments that cause incidents | 0–15% |
| **MTTR** (Mean Time to Restore) | Time to recover from a production incident | < 1 hour |

---

## How Metrics Are Emitted from This Pipeline

Metrics are pushed to the **Prometheus Pushgateway**
(`pushgateway.monitoring.svc.cluster.local:9091`, the Service in
`monitoring/pushgateway.yaml`) by `pushDoraMetric()` in the Jenkinsfile, from
the `post` block of the production deploy stage.

Each production build pushes its own group,
`/metrics/job/jenkins/instance/<JOB_NAME>-<BUILD_NUMBER>`, so every series
carries `job="jenkins"` and a per-build `instance`. All four are plain gauges:

| Metric | Pushed when | Value |
|--------|-------------|-------|
| `deployment_frequency_total` | deploy succeeded | `1` |
| `lead_time_seconds` | deploy succeeded | seconds from the HEAD commit to the deploy |
| `mttr_seconds` | deploy succeeded | seconds since the last failed build, `0` if none |
| `change_failure_total` | deploy failed | `1` |

Despite the `_total` suffix nothing is a counter: a deploy is one group with a
`1` in it, so queries **count groups** rather than taking `increase()`. The
Pushgateway adds `push_time_seconds` to every group; comparing it with
`time()` selects the builds in a window. Groups stay until they are deleted or
the Pushgateway restarts (it runs without a persistence file).

---

## Prometheus Scrape Config

The `pushgateway` job in kube-prometheus-stack's
`prometheus.prometheusSpec.additionalScrapeConfigs`
(`argocd/bootstrap/apps/kube-prometheus-stack.yaml`) scrapes it:

```yaml
- job_name: pushgateway
  honor_labels: true           # keep job/instance as Jenkins pushed them
  static_configs:
    - targets: ['pushgateway.monitoring.svc.cluster.local:9091']
```

---

## Querying DORA Metrics in Prometheus / Grafana

These are the queries in the DORA dashboard
(`monitoring/grafana/dashboards/dora.yaml`). `2592000` is 30 days in seconds.

### Deployment Frequency (deploys in the last 30 days)

```promql
count(
  deployment_frequency_total
  and on(job, instance) (push_time_seconds{job="jenkins"} > time() - 2592000)
) or vector(0)
```

### Lead Time for Changes (P50 and P95 over the last 30 days)

```promql
quantile(0.5,
  lead_time_seconds
  and on(job, instance) (push_time_seconds{job="jenkins"} > time() - 2592000)
)
```

Use `0.95` for P95, or `avg(...)` for the mean.

### Change Failure Rate (%)

Failed deploys over all deploys (successful + failed):

```promql
100 * (count(change_failure_total and on(job, instance) (push_time_seconds{job="jenkins"} > time() - 2592000)) or vector(0))
/ clamp_min(
    (count(deployment_frequency_total and on(job, instance) (push_time_seconds{job="jenkins"} > time() - 2592000)) or vector(0))
  + (count(change_failure_total and on(job, instance) (push_time_seconds{job="jenkins"} > time() - 2592000)) or vector(0)),
  1)
```

### MTTR (mean restore duration)

Successful builds with no earlier failure push `0`; leave them out:

```promql
avg(mttr_seconds > 0 and on(job, instance) (push_time_seconds{job="jenkins"} > time() - 2592000))
```

---

## Grafana Dashboard

`monitoring/grafana/dashboards/dora.yaml` is imported by the Grafana sidecar
(Argo CD app `grafana-dashboards`). Community DORA dashboards expect different
metric shapes and will not work against these gauges unchanged.

---

## References

- [DORA State of DevOps Report](https://dora.dev/research/)
- [Prometheus Pushgateway](https://github.com/prometheus/pushgateway)
- `monitoring/pushgateway.yaml` — Kubernetes Deployment + Service
- `argocd/bootstrap/apps/kube-prometheus-stack.yaml` — the `pushgateway` scrape job
- `monitoring/grafana/dashboards/dora.yaml` — the DORA dashboard
