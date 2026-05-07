# Performance Baseline Guide

This document explains how the k6 performance baseline works, when to update it, and how to run the comparison locally.

---

## What is the baseline?

`tests/performance/baseline.json` contains reference values from a known-good run of the k6 load test against a stable build. The `compare-baseline.js` script reads the live k6 output and compares it against these values, failing the build if any metric regresses beyond its allowed threshold.

### Current thresholds (judgment calls)

| Metric | Allowed regression | Rationale |
|---|---|---|
| `http_req_duration.p95` | +20% | 95th-percentile tail latency; 20% headroom absorbs normal run-to-run variance |
| `http_req_duration.p99` | +25% | 99th-percentile is noisier, so a wider band prevents false positives |
| `http_req_failed.rate` | 2× baseline | Error rate doubling (e.g. 0.2% → 0.4%) is always significant |

These are starting thresholds. Tighten them once the pipeline accumulates several stable runs and the variance is understood.

---

## How the baseline is established

1. Deploy a known-stable build to staging.
2. Run k6 against it and save the NDJSON output:
   ```sh
   k6 run --out json=/tmp/k6-stable.json \
     --env BASE_URL=https://staging.my-app.internal \
     tests/performance/load-test.js
   ```
3. Extract the summary values you want to commit. The easiest approach is to let `compare-baseline.js` print the "Current" column and copy those numbers into `baseline.json`:
   ```sh
   node tests/performance/compare-baseline.js \
     --current  /tmp/k6-stable.json \
     --baseline tests/performance/baseline.json
   ```
   (This will likely FAIL because the current file is different from baseline — that is fine. Look at the "Current" column in the printed table.)
4. Update `tests/performance/baseline.json` with the new values, set `captured_at` to today's ISO-8601 UTC timestamp, and set `git_sha` to the commit SHA of the stable build.
5. Commit the updated baseline on a dedicated commit with a message like:
   ```
   perf: re-baseline after <description of change>
   ```

---

## When to re-baseline

**Re-baseline when:**
- A legitimate performance-improving change is merged (e.g. query optimisation, caching layer, connection pooling). The new baseline captures the improvement so future regressions are caught relative to the better level.
- Infrastructure changes alter the baseline irreversibly (e.g. new node class, changed region, new load balancer).
- The load-test scenario itself changes (different VU counts, new routes).

**Do NOT re-baseline to mask regressions.** If the pipeline fails because a new feature made the API slower, fix the performance problem — do not silently update the baseline to accept the regression. Baselines exist precisely to catch this class of drift.

---

## Running the comparison locally

Prerequisites: Node.js (same version as CI), a running instance of the app (or access to staging).

```sh
# 1. Run k6 against your local instance
k6 run --out json=/tmp/k6-local.json \
  --env BASE_URL=http://localhost:3000 \
  tests/performance/load-test.js

# 2. Compare against the committed baseline
node tests/performance/compare-baseline.js \
  --current  /tmp/k6-local.json \
  --baseline tests/performance/baseline.json
```

The script prints a table like:

```
k6 Baseline Comparison — Build 020
Baseline captured: 2026-05-07T00:00:00Z  git_sha: BASELINE
Current results:   /tmp/k6-local.json

Metric                          Baseline      Current      Delta%    Threshold   Status
------------------------------  ------------  -----------  --------  ----------  --------
http_req_duration.p95 (ms)      320.0         298.5        -6.7%     +20%        OK
http_req_duration.p99 (ms)      850.0         810.0        -4.7%     +25%        OK
http_req_failed.rate            0.0020        0.0015       -25.0%    +100%       OK

RESULT: PASS — all metrics within regression thresholds.
```

A non-zero exit code means at least one metric failed. The "Delta%" column shows the direction: negative = improvement, positive = regression.

---

## Where the baseline file lives

`tests/performance/baseline.json` — committed to the repository. CI reads it at run time; it does not need to be rebuilt or generated as part of the pipeline.

## Related files

- `tests/performance/load-test.js` — the k6 load-test scenario
- `tests/performance/compare-baseline.js` — the comparison script
- `Jenkinsfile` stage `Performance Tests` — invokes both scripts in sequence
