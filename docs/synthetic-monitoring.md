# Synthetic Monitoring

**Last updated:** Build 022  
**Related docs:** `docs/runbook.md` (alert routing), `docs/perf-baseline.md` (k6 baselines)

---

## What Is Synthetic Monitoring?

Synthetic monitoring runs scripted probes against your service on a fixed schedule,
regardless of whether real users are active. This is fundamentally different from
real-user monitoring (RUM), which only fires when traffic flows.

**Why it matters:**

- Catches regressions at 03:00 on a Sunday when no users are present.
- Validates that the `/health/ready` contract is upheld from outside the cluster
  (not just from inside Kubernetes probes).
- Provides a consistent baseline for SLO availability calculations — you control
  the probe frequency, so you know exactly how many "opportunities" exist in the
  measurement window.
- Detects geographic or CDN-layer issues that internal cluster monitoring misses.

**Reactive metrics (Prometheus + Grafana)** tell you what happened to real users.
**Synthetic probes** tell you what would happen to a user right now, even if no
real users exist yet.

---

## Self-Hosted Option: k6 CronJob

For teams that want synthetic monitoring without a SaaS bill, a Kubernetes
`CronJob` running [k6](https://k6.io/) every 5 minutes is a pragmatic starting
point.

**How it would work:**

1. A `CronJob` in the `monitoring` namespace runs a k6 script every 5 minutes.
2. k6 hits the production endpoints: `/health/live`, `/health/ready`, `/api/items`.
3. Results are exported to Prometheus via the k6 Prometheus remote-write output
   or the StatsD bridge (`K6_STATSD_ENABLE_TAGS=true`).
4. Grafana dashboards visualise probe duration and pass/fail over time.
5. A Prometheus alert fires if the probe fails 2 consecutive times.

**Sketch of `monitoring/synthetic-cron.yaml`** (not committed — opt in when ready):

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: synthetic-probe
  namespace: monitoring
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: k6
              image: grafana/k6:0.54.0
              args:
                - run
                - --out
                - experimental-prometheus-rw
                - /scripts/probe.js
              env:
                - name: K6_PROMETHEUS_RW_SERVER_URL
                  value: http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/write
                - name: BASE_URL
                  value: https://production.app.example.com
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
          volumes:
            - name: scripts
              configMap:
                name: synthetic-probe-scripts
```

> **Note:** Do not commit this manifest until you have verified the k6 image is
> available in your container registry and the Prometheus remote-write endpoint
> is reachable from the `monitoring` namespace.

---

## SaaS Options

For teams that need geo-distributed checks, SLA-backed alerting, or no-ops
maintenance overhead:

| Tool | Free tier | Paid starts at | Geo checks | Notes |
|------|-----------|---------------|------------|-------|
| [Checkly](https://www.checklyhq.com/) | 10K check runs/mo | ~$20/mo | Yes (20+ locations) | k6-compatible scripts; CI/CD integration; Playwright support |
| [Pingdom](https://www.pingdom.com/) | None | ~$15/mo | Yes (100+ locations) | Established tool; good uptime SLA reports |
| [UptimeRobot](https://uptimerobot.com/) | 50 monitors, 5-min interval | ~$7/mo | No (single location) | Simple HTTP checks; good for small projects |
| [Better Stack](https://betterstack.com/) | 10 monitors | ~$24/mo | Yes (multiple regions) | Incident management + status pages included |

**Pricing as of 2025 — verify current pricing on vendor sites.**

---

## Recommendation

**Start with the self-hosted k6 CronJob.** It costs nothing extra (reuses existing
Prometheus + Grafana), uses the same k6 scripts already in `tests/performance/`,
and gives you single-location coverage immediately.

**Promote to a SaaS tool** when you need one or more of:

- Geo-distributed probes (detect regional CDN or DNS failures)
- SLA-backed alerting with an external incident timeline
- Status page for customer-facing uptime communication
- The ops overhead of maintaining the CronJob + scripts outweighs the SaaS cost

**Until then:** the k6 CronJob + Prometheus alert (`docs/runbook.md` §Synthetic
Probe Failures) is sufficient for a single-region deployment.

---

## Alert Routing

When a synthetic probe fails, route the alert through the same path as other
availability alerts. See `docs/runbook.md` for:

- Alert definitions (`SyntheticProbeFailure`)
- On-call escalation path
- Runbook steps for investigating probe failures vs real outages
