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

Metrics are pushed to the **Prometheus Pushgateway** (`pushgateway:9091`) at key
Jenkinsfile stage transitions.  The Pushgateway is deployed in the `monitoring`
namespace via `monitoring/pushgateway.yaml`.

### Deployment Frequency & MTTR anchor

After a successful production deploy (sketch — do not edit Jenkinsfile):

```groovy
// Jenkinsfile — "Deploy to Production" post { success { ... } }
sh """
  DEPLOY_TS=\$(date +%s)
  cat <<PROM | curl -s --data-binary @- \
      http://pushgateway:9091/metrics/job/cicd/instance/\${env.BUILD_TAG}
deployment_timestamp_seconds{env="production",version="\${IMAGE_TAG}"} \${DEPLOY_TS}
deployment_result{env="production",version="\${IMAGE_TAG}",result="success"} 1
PROM
"""
```

On a rollback or incident-closure event:

```groovy
sh """
  RESTORE_TS=\$(date +%s)
  cat <<PROM | curl -s --data-binary @- \
      http://pushgateway:9091/metrics/job/cicd/instance/\${env.BUILD_TAG}
deployment_result{env="production",version="\${IMAGE_TAG}",result="failure"} 1
restore_timestamp_seconds{env="production",version="\${IMAGE_TAG}"} \${RESTORE_TS}
PROM
"""
```

### Lead Time for Changes

Lead time is recorded at the end of the pipeline using the timestamp of the
first commit on the branch and the production deploy timestamp:

```groovy
sh """
  FIRST_COMMIT_TS=\$(git log --reverse --format='%ct' origin/main..HEAD | head -1)
  DEPLOY_TS=\$(date +%s)
  LEAD_TIME=\$((DEPLOY_TS - FIRST_COMMIT_TS))
  cat <<PROM | curl -s --data-binary @- \
      http://pushgateway:9091/metrics/job/cicd/instance/\${env.BUILD_TAG}
lead_time_seconds{env="production",version="\${IMAGE_TAG}"} \${LEAD_TIME}
PROM
"""
```

---

## Prometheus Scrape Config

Add the following job to `prometheus.yml` `scrape_configs` so Prometheus polls
the Pushgateway:

```yaml
- job_name: 'pushgateway'
  honor_labels: true           # preserve job/instance labels set by the pusher
  static_configs:
    - targets: ['pushgateway:9091']
```

This is included as a comment at the top of `monitoring/pushgateway.yaml` for
reference.

---

## Querying DORA Metrics in Prometheus / Grafana

### Deployment Frequency (deploys per day, 30-day window)

```promql
count_over_time(
  deployment_timestamp_seconds{env="production"}[30d]
) / 30
```

### Lead Time for Changes (P50 and P95 over last 30 days)

```promql
# P50
histogram_quantile(0.50,
  sum(rate(lead_time_seconds_bucket{env="production"}[30d])) by (le)
)

# P95
histogram_quantile(0.95,
  sum(rate(lead_time_seconds_bucket{env="production"}[30d])) by (le)
)
```

> **Note:** For `lead_time_seconds` to be queryable as a histogram the push
> payload should use the `_bucket`/`_count`/`_sum` convention.  For a simpler
> gauge-style push, use `avg_over_time` instead.

### Change Failure Rate

```promql
sum(deployment_result{env="production", result="failure"})
/
sum(deployment_result{env="production"})
```

### MTTR (mean restore duration)

```promql
avg(
  restore_timestamp_seconds{env="production"}
  - on(version) deployment_timestamp_seconds{env="production"}
)
```

---

## Grafana Dashboard Sketch

Import the "DORA Metrics" community dashboard (ID **10128**) and point it at
your Prometheus data source.  Override the label selectors to match the
`env="production"` label used above.

---

## References

- [DORA State of DevOps Report](https://dora.dev/research/)
- [Prometheus Pushgateway](https://github.com/prometheus/pushgateway)
- `monitoring/pushgateway.yaml` — Kubernetes Deployment + Service
- `monitoring/prometheus.yaml` — scrape config comment
