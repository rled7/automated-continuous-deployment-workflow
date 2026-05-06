# On-Call Rotation

This document covers who is on call, what is expected of them, the escalation contract, tooling, and how to hand off the rotation.

---

## Rotation Cadence

- **Schedule:** Weekly rotation, 7 days on / 7 days off.
- **Handoff time:** Every Monday at 10:00 local time for the incoming engineer.
- **Schedule source of truth:** PagerDuty — see [PagerDuty Schedule (placeholder)](https://your-org.pagerduty.com/schedules#REPLACE_ME).
- Rotations are planned at least two weeks in advance. Swap requests must be agreed between both engineers and updated in PagerDuty before Monday.

---

## Roles

### Primary On-Call

The primary is the first responder for all pages.

**Responsibilities:**
- Acknowledge pages within 15 minutes.
- Begin active investigation within 30 minutes of the page.
- Drive incidents to resolution or escalate if not resolved within 1 hour.
- File a postmortem for every Sev 1 and Sev 2 (use `docs/postmortem-template.md`).
- Complete the handoff checklist before passing the rotation (see below).

### Secondary On-Call

The secondary backs up the primary and handles overflow.

**Responsibilities:**
- Be available to be paged if the primary does not acknowledge within 15 minutes.
- Join active Sev 1 incidents to assist, even if not paged directly.
- Shadow the primary to stay familiar with current incidents and operational state.

---

## Escalation Contract

| Step | Trigger | Action |
|------|---------|--------|
| 1 | Page fires | Primary acknowledges within **15 minutes** |
| 2 | No ack from primary after 15 min | PagerDuty escalates to secondary |
| 3 | No ack from secondary after 30 min | PagerDuty escalates to engineering lead |
| 4 | Not resolved within **1 hour** of page | Primary manually escalates to engineering lead + posts in `#incidents` |
| 5 | Sev 1 not resolved within **2 hours** | Engineering lead escalates to VP Engineering |

Response SLA summary:
- **Acknowledge:** 15 minutes from page
- **Incident response begins:** 30 minutes from page
- **Escalate if unresolved:** 1 hour from page

---

## What Is Expected

- Respond to pages promptly — even at night and on weekends.
- Drive incidents to resolution: coordinate, delegate, communicate status.
- Post status updates in `#incidents` at least every 30 minutes during an active Sev 1.
- Update the `/status` page (or equivalent) for customer-facing incidents.
- Complete a postmortem for every Sev 1 or Sev 2 within 48 hours of resolution.
- Hand off cleanly using the checklist below.

---

## What Is NOT Expected

- Feature development or code review during on-call week (unless you choose to).
- Being awake 24/7 — respond within the SLA windows above.
- Resolving incidents that are outside your expertise alone — escalate early.
- Continuing on call when you are too fatigued to work safely — swap with your secondary.

---

## Tooling

| Tool | Purpose | Link |
|------|---------|------|
| PagerDuty | Alerting + escalation | [Schedule (placeholder)](https://your-org.pagerduty.com/schedules#REPLACE_ME) |
| Grafana | Dashboards (RED, SLO, DORA, pipeline) | `http://grafana.example.com` |
| Alertmanager | Alert routing + silencing | `http://alertmanager.example.com` |
| Slack `#incidents` | Incident coordination | Internal |
| Slack `#alerts-warning` | Warning-level alerts | Internal |
| Slack `#alerts-critical` | Critical-level alerts | Internal |
| Jenkins | CI/CD pipelines + build history | `http://jenkins.example.com` |
| Kubernetes | Cluster access | `kubectl config use-context production` |
| Loki / Grafana | Log exploration | Explore → Loki datasource |
| Tempo / Grafana | Distributed traces | Explore → Tempo datasource |

---

## Cloud Cost Monitoring

OpenCost is used for cloud cost visibility. It is **not** deployed on kind (local development) but is required in production and staging clusters.

To install OpenCost:
```bash
kubectl apply -f https://raw.githubusercontent.com/opencost/opencost/develop/kubernetes/opencost.yaml
```

OpenCost exposes a dashboard at port 9090 on the `opencost` service in the `opencost` namespace. Use it to identify unexpected cost spikes during incidents (e.g., runaway jobs, oversized node groups). During Sev 1 incidents with cost implications, check the OpenCost dashboard alongside Grafana.

---

## Compensation Policy

*Placeholder — update with your organisation's policy before publishing.*

Engineers on primary on-call receive [compensation per on-call week / per incident page / equivalent time-off — fill in]. Out-of-hours pages (18:00–08:00 local or weekends) are additionally compensated at [rate/policy]. Contact your manager or People team for details.

---

## Handoff Checklist

Complete this checklist before handing the rotation to the incoming engineer. Do it synchronously — a 15-minute handoff call is recommended.

- [ ] Walk through all **open incidents** and their current status.
- [ ] Review any **active alert silences** in Alertmanager (explain why each exists and when to lift it).
- [ ] Flag any **ongoing experiments** or feature flags that could affect production behaviour.
- [ ] Share **known issues** or degraded dependencies (e.g., upstream API instability).
- [ ] Review outstanding **action items** from recent postmortems.
- [ ] Confirm the incoming engineer's PagerDuty schedule is active and contact details are correct.
- [ ] Share any **context not in the runbook** — e.g., "the cache has been flapping on Thursdays, we're investigating."
- [ ] Confirm the incoming engineer has access to all required tooling.

---

## Escalation Matrix

| Severity | Description | Primary Contact | Escalation (1h) | Escalation (2h) |
|----------|-------------|----------------|-----------------|-----------------|
| Sev 1 | Complete outage / data loss | On-call primary | Engineering lead | VP Engineering |
| Sev 2 | Significant degradation (error rate >5%, P95 >1s) | On-call primary | Engineering lead | — |
| Sev 3 | Minor degradation, no customer impact | On-call primary | Next business day | — |
| Sev 4 | Cosmetic / informational | Ticket only | — | — |

*For rotation details and PagerDuty links see the PagerDuty schedule above. For the full incident response procedure including postmortem requirements see `docs/postmortem-template.md`.*
