# Chaos Engineering

**Last updated:** Build 022  
**Related docs:** `chaos/README.md` (hands-on experiment guide), `docs/runbook.md` (alert routing)

---

## Why Chaos Engineering?

Monitoring and alerts tell you when something goes wrong. Chaos engineering tests
whether your monitoring, alerts, autoscaling, and runbooks work **before** a real
incident forces the question.

Without chaos experiments, you are relying on untested assumptions:

- "HPA will scale out before users notice." (Has it ever been triggered in staging?)
- "The app returns 503 when the DB is down." (Has that code path been exercised?)
- "Argo Rollouts will pause if error rate spikes." (Has the analysis template been validated?)

Chaos engineering replaces assumptions with evidence. Each experiment is a
controlled hypothesis test with a defined blast radius.

---

## Workflow: Hypothesize → Observe → Refine

Every experiment follows this loop:

1. **Hypothesize** — write down what you expect to happen. Be specific:
   > "When 50% of pods are killed, p99 latency stays below 500ms because
   > the surviving pods absorb traffic and new pods are scheduled within 30s."

2. **Small blast radius** — start with one pod, one namespace, short duration.
   Widen the scope only after the hypothesis holds at the smaller scale.

3. **Observe** — watch Grafana dashboards, pod events, and HPA metrics in real time.
   Record what actually happened.

4. **Refine** — if the hypothesis is violated, find and fix the gap. Then re-run
   the experiment to confirm the fix. Iterate until the system behaves as designed.

---

## The Four Canonical Experiments

These four experiments cover the most common failure modes for a containerised,
database-backed API. Manifests live in `chaos/`.

### 1. Pod Failure — `chaos/pod-failure.yaml`

**Question:** Does autoscaling and pod rescheduling recover the service?

**Hypothesis:** When 50% of `app: my-app` pods are killed in staging, Kubernetes
reschedules them within 30s. The surviving pods absorb traffic. `/health/ready`
stays 200 throughout (served by surviving pods).

**Key observations:**
- Time from pod deletion to replacement pod `Running` state
- HPA desired-replica count during recovery
- p99 latency spike during the recovery window
- Whether any in-flight requests were dropped (5xx in access logs)

**Pass criterion:** p99 latency stays below SLO threshold; no sustained 5xx.

---

### 2. Network Delay — `chaos/network-delay.yaml`

**Question:** Do timeout settings behave correctly under high latency?

**Hypothesis:** 100ms ± 30ms added latency to DB egress traffic increases API
response times by a similar amount but does not cause timeouts or 5xx errors,
because the DB client timeout is set to ≥ 500ms.

**Key observations:**
- API p95/p99 latency during the experiment
- Whether DB client timeout errors appear in app logs
- Whether the latency is absorbed gracefully or causes cascading failures

**Pass criterion:** No timeout errors in logs; latency increases proportionally;
no 5xx responses.

**Common failure:** DB client timeout configured too aggressively (e.g., 50ms).
Fix: increase to 500ms–1s; add retry with exponential backoff.

---

### 3. CPU Stress — `chaos/cpu-stress.yaml`

**Question:** Does HPA scale out? Does Argo Rollouts pause during instability?

**Hypothesis:** When one pod is stressed to 80% CPU, the HPA detects elevated
average CPU across the deployment and scales out within 90s. If an active Rollouts
revision is in progress, the analysis step detects the elevated error rate and
pauses the rollout.

**Key observations:**
- HPA `TARGETS` and `REPLICAS` during the experiment (`kubectl get hpa -n staging -w`)
- Whether Argo Rollouts pauses or continues a concurrent rollout
- Whether the stressed pod is CPU-throttled (check `kubectl top pods`) or hits
  its CPU limit and introduces latency

**Pass criterion:** HPA scales to ≥ target replicas; no sustained degradation
to end users.

---

### 4. Network Partition — `chaos/network-partition.yaml`

**Question:** Does `/health/ready` flip to 503 when the DB is unreachable?

**Hypothesis:** A 30s full partition between `app: my-app` and `app: app-db`
causes the app's readiness probe to fail (because the DB health check fails),
Kubernetes removes the pods from the Endpoints list, and the Service stops routing
traffic to them. `/health/ready` returns 503 during the partition and recovers to
200 within one probe cycle after the partition ends.

**Key observations:**
- Time from partition start to first 503 on `/health/ready`
- Whether in-flight DB queries fail gracefully or cause 500 responses
- Time from partition end to first 200 on `/health/ready` (readiness probe recovery)
- Whether the app reconnects to the DB automatically (no manual pod restart needed)

**Pass criterion:** 503 during partition (not 500); clean recovery within probe
period after partition ends; no data corruption.

---

## Game-Day Cadence

**Recommended schedule:** Monthly, on a fixed weekday (e.g., first Tuesday of the month).

**Format (2–3 hours):**

| Time | Activity |
|------|----------|
| T+00 | Brief: review previous action items; choose experiments for today |
| T+15 | Warm up: verify staging is healthy before starting |
| T+30 | Run experiments (start with smallest blast radius) |
| T+90 | Debrief: what broke, what held, what was surprising |
| T+120 | Action items: file tickets for each gap found |
| T+150 | Update chaos diary in the team wiki |

**Workshop format for larger teams:**

Split into two groups: one runs experiments, one plays the role of on-call
responder (receives alerts as if it were a real incident, follows the runbook
without being told what experiment is running). This tests both the system and
the operational response simultaneously.

---

## Connection to SLOs

Every chaos experiment should refine at least one SLI.

| Experiment | SLI refined |
|------------|-------------|
| Pod failure | Availability (% successful requests) |
| Network delay | Latency (p99 response time) |
| CPU stress | Availability + latency under load |
| Network partition | Availability (readiness probe behaviour) |

After each experiment:
1. Check whether the SLO window was violated during the blast.
2. If yes, fix the gap and re-run until the SLO holds.
3. If no, tighten the SLO target or increase the blast radius.

The goal is a system where **your SLO holds even during chaos experiments in staging**.
That is evidence (not assumption) that it will hold during real incidents.

---

## Hands-On Use

See `chaos/README.md` for:
- How to apply, observe, and stop each experiment
- The full experiment catalogue
- Safety gates (namespace rules, blast radius guidance)
- Chaos diary template
