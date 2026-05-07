# Chaos Engineering Experiments

This directory contains [Chaos Mesh](https://chaos-mesh.org/) experiment manifests
for testing application resilience in the `staging` namespace.

> **SAFETY RULE:** Never apply these manifests directly to the `production` namespace.
> Every experiment targets `staging`. If you want to run chaos against production,
> implement an explicit approval workflow (e.g., Argo Workflows gate + PagerDuty
> alert suppression window) first.

---

## Prerequisites

- Chaos Mesh installed via `argocd/bootstrap/apps/chaos-mesh.yaml`
- A running `staging` namespace with `app: my-app` and `app: app-db` pods
- Sufficient observability: Grafana dashboards + Prometheus alerts active

---

## Running an Experiment

### 1. Apply the experiment manifest

```bash
kubectl apply -f chaos/pod-failure.yaml
```

### 2. Observe what happens

Each experiment manifest has a hypothesis comment. Use the commands below to observe:

```bash
# PodChaos
kubectl describe podchaos pod-failure-staging -n staging
kubectl get pods -n staging -w

# NetworkChaos
kubectl describe networkchaos network-delay-staging -n staging
kubectl describe networkchaos network-partition-staging -n staging

# StressChaos
kubectl describe stresschaos cpu-stress-staging -n staging
kubectl top pods -n staging -l app=my-app

# IOChaos
kubectl describe iochaos io-delay-staging -n staging
```

Check Grafana for latency / error-rate spikes during the experiment window.

### 3. Stop the experiment

Experiments self-terminate at their `duration`. To stop early:

```bash
kubectl delete -f chaos/pod-failure.yaml
```

---

## Experiment Catalogue

| File | Kind | Action | Target | Duration | Blast Radius |
|------|------|--------|--------|----------|--------------|
| `pod-failure.yaml` | PodChaos | pod-failure | `app: my-app` | 60s | 50% of pods |
| `network-delay.yaml` | NetworkChaos | delay (egress) | `my-app` → `app-db` | 2m | 100ms ± 30ms |
| `network-partition.yaml` | NetworkChaos | partition (both) | `my-app` ↔ `app-db` | 30s | Full partition |
| `cpu-stress.yaml` | StressChaos | CPU 80% | `app: my-app` | 60s | 1 random pod |
| `io-delay.yaml` | IOChaos | latency | `/app/logs` volume | 60s | 1 random pod |

---

## Workflow: Hypothesize → Observe → Refine

Every experiment follows this loop:

1. **State the hypothesis** — what do you expect to happen? Write it down before running.
2. **Set up observation** — open Grafana dashboards, watch `kubectl get pods -w`.
3. **Apply the experiment** — small blast radius first.
4. **Record observations** — does the system behave as expected?
5. **Refine** — if the hypothesis is violated, fix the gap (alert, timeout, retry) and re-run.

### Chaos Diary

After each experiment session, record findings in a `chaos-diary.md` (not committed —
store in your team wiki or incident tracker). Minimum entries:

- Date and who ran it
- Which experiment
- Hypothesis
- What actually happened
- Action items (e.g., "reduce DB timeout from 5s to 500ms")

---

## Game-Day Cadence

Suggested schedule: **monthly**, on a fixed weekday (e.g., first Tuesday).

**Recommended game-day format (2–3 hours):**

1. (15 min) Brief: review previous action items; choose today's experiments.
2. (60 min) Run experiments in staging; record observations.
3. (30 min) Debrief: what broke, what held, what was surprising.
4. (30 min) Action items: file tickets for gaps found.
5. (15 min) Update chaos diary.

---

## Safety Gates

- Namespace must contain `staging` in the name — never `production`.
- Always confirm blast radius before applying (check `mode` and `value` fields).
- Have a `kubectl delete` command ready before applying any experiment.
- Schedule game days outside business hours if the staging environment is shared
  with QA or integration tests.
- Notify the team in Slack (`#ops` or equivalent) before and after experiments.

---

## Further Reading

- `docs/chaos-engineering.md` — why we do chaos engineering, the canonical
  experiments, and how results connect to SLOs.
- [Chaos Mesh docs](https://chaos-mesh.org/docs/) — full CRD reference.
- [Chaos Engineering principles](https://principlesofchaos.org/) — the original
  Netflix methodology.
