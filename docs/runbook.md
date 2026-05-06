# Operational Runbook — my-app

## Quick links

| Resource | URL / contact |
|----------|---------------|
| Jenkins CI | `http://jenkins.example.com` |
| Grafana dashboards | `http://grafana.example.com` |
| Slack ops channel | `#ops-alerts` |
| On-call rotation | See `docs/oncall.md` and [PagerDuty (placeholder)](https://your-org.pagerduty.com/schedules#REPLACE_ME) |
| Kubernetes cluster | `kubectl config use-context production` |
| Postmortem template | `docs/postmortem-template.md` — use after every Sev 1/2 |
| DORA metrics | `docs/dora-metrics.md` — measure incident impact on deployment frequency + MTTR |

---

## Common alerts and actions

### HighErrorRate

**Trigger:** HTTP 5xx rate > 5% for 2 minutes.

**Likely causes:** Bad deploy, upstream dependency failure, OOM kill.

**Actions:**
1. Check logs: `kubectl logs -l app=my-app -n production --tail=100`
2. Check recent deploys: `kubectl rollout history deployment/my-app -n production`
3. Check upstream dependencies (DB, Redis) are reachable.
4. If a bad deploy, roll back (see Rollback section below).
5. If upstream, escalate to the relevant service owner.

---

### HighResponseTime

**Trigger:** P95 response time > 500 ms for 5 minutes.

**Likely causes:** Database slow query, Redis latency, CPU throttling, insufficient replicas.

**Actions:**
1. Check HPA status: `kubectl get hpa -n production`
2. Review slow DB queries via DB monitoring dashboards.
3. Check pod CPU/memory: `kubectl top pods -n production`
4. If CPU-bound, scale manually: `kubectl scale deployment/my-app --replicas=<N> -n production`
5. Raise an incident and page the on-call engineer if P95 > 1s.

---

### AppDown

**Trigger:** `up{job="my-app"} == 0` for 1 minute (Prometheus cannot scrape any pod).

**Likely causes:** All pods crashing, no ready endpoints, network policy issue.

**Actions:**
1. Check pod status: `kubectl get pods -n production -l app=my-app`
2. Describe a failing pod: `kubectl describe pod <pod-name> -n production`
3. View crash logs: `kubectl logs <pod-name> -n production --previous`
4. Verify the Service and Ingress: `kubectl get svc,ingress -n production`
5. If all pods are crash-looping, roll back immediately (see below).
6. Page on-call if not resolved within 5 minutes.

---

### PodRestartingFrequently

**Trigger:** Container restart count increases by > 3 in the last hour.

**Likely causes:** OOMKilled, liveness probe misconfiguration, unhandled exception on startup.

**Actions:**
1. Check exit reason: `kubectl describe pod <pod-name> -n production | grep -A5 "Last State"`
2. If OOMKilled, raise memory limits in `k8s/overlays/production/` and redeploy.
3. If liveness probe failing, check `/health/live` endpoint manually.
4. Review app logs around the time of the restart.

---

## Rollback procedures

### Automatic rollback (Jenkinsfile)

The `post { failure }` block in the Jenkinsfile calls `kubectl rollout undo deployment/my-app -n <namespace>` automatically when a post-deploy smoke test fails. No manual action required in normal circumstances.

### Manual rollback

```bash
# Roll back to the previous revision
kubectl rollout undo deployment/my-app -n production

# Roll back to a specific revision (check history first)
kubectl rollout history deployment/my-app -n production
kubectl rollout undo deployment/my-app --to-revision=<N> -n production

# Monitor rollout progress
kubectl rollout status deployment/my-app -n production
```

---

## Hotfix procedure

Use this when a critical bug is found in production and cannot wait for the normal release cycle.

1. Branch from `main`: `git checkout -b hotfix/<description> main`
2. Make the minimal fix and add a regression test.
3. Open a PR against `main` — get at least one approval.
4. After merge, Jenkins deploys automatically.
5. Cut a patch release (see `docs/RELEASING.md`).
6. Back-merge `main` into `develop`: `git merge main` (resolve conflicts if any).

---

## Escalation path

| Severity | First responder | Escalate to | Escalate after |
|----------|----------------|-------------|----------------|
| Critical (AppDown, data loss) | On-call engineer | Engineering lead | 15 minutes |
| High (HighErrorRate, HighResponseTime > 1s) | On-call engineer | Team channel | 30 minutes |
| Medium / Low | Next business day | — | — |

---

## After an incident

Every Sev 1 or Sev 2 incident requires a blameless postmortem within 48 hours of resolution.

1. Copy `docs/postmortem-template.md` and rename it `docs/postmortems/INC-YYYY-NNN.md`.
2. Fill in all sections while the incident is fresh. A rough draft in the first hour beats a polished document a week later.
3. Schedule a 30-minute review meeting within one week. Invite everyone who was involved.
4. Publish the completed postmortem in the `#incidents` Slack channel.
5. Track all action items as tickets (P1 items must be resolved before the next production deploy).
6. Review DORA metrics after the incident — see `docs/dora-metrics.md` for how incidents affect Deployment Frequency, Change Failure Rate, and MTTR.

For the on-call rotation, escalation contacts, and response SLAs see `docs/oncall.md`.

---

## Production access

- All production `kubectl` access requires a valid kubeconfig (distributed via the `kubeconfig` Jenkins credential and team 1Password vault).
- Direct database access in production requires VP engineering approval and must be logged.
- Never run destructive commands (`kubectl delete`, `DROP TABLE`, etc.) without a peer review.
