# Benchmarks

Two developer-facing benchmarks. **Neither runs on push.** Both are opt-in via `make` or direct script invocation.

| Benchmark | What it measures | Typical use |
|---|---|---|
| `make bench-pipeline` | How long each CI-equivalent step takes locally (lint, build, unit + integration tests, kustomize render, kubeconform, repo sanity check, optional Docker build) | "Why is the build slow? Is it tests, lint, or the docker layer?" |
| `make bench-app` | Latency + throughput per API endpoint (p50 / p95 / p99 / avg / req/s) | "Did my last change regress response time?" or "What's the steady-state throughput on this machine?" |

Both can also run with `--json` for diffing across runs or capturing a checked-in baseline.

## Why these aren't on push

- **Pipeline timing varies dramatically** by machine (M-series laptop vs ancient ThinkPad vs CI agent). A regression check that's noisy 50% of the time isn't a useful signal — it's just noise. Keep the baseline machine-local.
- **App benchmark needs ~10–60 seconds** of stable load. Adding it to the per-PR Jenkins flow would slow every PR for almost no signal that k6 (which already runs against staging post-deploy) doesn't already give.
- The right place for "did the perf get worse?" gating is `tests/performance/load-test.js` + `tests/performance/compare-baseline.js` — that runs against staging, against fixed infrastructure, and is already wired into the Jenkinsfile.

## Quick start

```bash
# How fast is each pipeline step on this machine?
make bench-pipeline

# Latency for every API route (default: 500 reqs @ 10 concurrency)
make bench-app

# Both back-to-back
make bench

# Re-capture baselines after a deliberate perf improvement
make bench-update-baseline
```

## Pipeline benchmark

Times each step in sequence:

```
▸ Pipeline benchmark
  lint                            1715ms  ✓
  build                            164ms  ✓
  test:unit                       2990ms  ✓
  test:integration                1752ms  ✓
  kustomize:production              42ms  ✓     (skipped if kubectl/kustomize absent)
  kustomize:staging                 41ms  ✓
  kubeconform                      230ms  ✓     (skipped if kubeconform absent)
  check-repo                      1785ms  ✓
  docker:build                   38000ms  ✓     (skipped with --no-docker)

  ──────                            ────
  TOTAL                           8406ms
```

Steps are skipped (with a note) if their tools aren't on PATH. `--no-docker` skips the Docker build, which is by far the longest step.

### Comparing against a baseline

```bash
./scripts/benchmark-pipeline.sh --compare benchmarks/pipeline-baseline.json
```

Prints `was Xms, +Y%` deltas next to each step. Used during local optimisation work.

## App benchmark

Boots the app on a sandbox port (default 3099) with `DB_FAKE=1 REDIS_FAKE=1` so no Postgres/Redis needed. Fires N requests at concurrency C. Measures wall-clock per request via `process.hrtime.bigint()`.

```
▸ App benchmark — 500 requests / 10 concurrency / port 4099
  GET   /health/live        p50=  5.9ms  p95= 17.1ms  p99= 24.4ms  avg=  7.4ms   1311 req/s  errs=0
  GET   /health/ready       p50=  6.6ms  p95= 15.5ms  p99= 22.7ms  avg=  7.9ms   1243 req/s  errs=0
  GET   /api/items          p50=  6.2ms  p95= 18.8ms  p99= 28.1ms  avg=  8.0ms   1233 req/s  errs=0
  POST  /api/items          p50=  …      p95= …       p99= …       avg= …        … req/s     errs=…
  GET   /metrics            p50=  …      p95= …       p99= …       avg= …        … req/s     errs=…
  GET   /openapi.yaml       p50=  2.1ms  p95=  4.2ms  p99=  5.1ms  avg=  2.4ms   1997 req/s  errs=0
```

Numbers above are **example baseline** captured on a development sandbox; treat your own machine's numbers as the canonical baseline. Commit `benchmarks/app-baseline.json` only if the workflow is for a single shared dev machine.

### Args

- `--requests N` — total requests per endpoint (default 500)
- `--concurrency C` — concurrent in-flight requests (default 10)
- `--port P` — sandbox port the app binds to (default 3099)
- `--json` — emit JSON to stdout instead of the formatted table

### What it does NOT measure

- Network latency (it's localhost — every request is sub-1-ms in transport).
- Realistic database/Redis load (data layer is faked).
- Cold-start time (the warm-up requests are folded into the p50/p95).
- Full traffic shapes (no ramp, no spike). For that, use `tests/performance/load-test.js` against staging.

This is **inner-loop signal** for "is my code change faster or slower than yesterday's", not a production SLA gate.

## Updating the baseline

When a perf improvement is intentional and you want future runs compared against the new fast number:

```bash
make bench-update-baseline
git diff benchmarks/
git commit -am "chore(bench): re-baseline after <change>"
```

Don't routinely update — the point of comparing against baseline is to catch unintended regressions.

## Files

```
scripts/benchmark-pipeline.sh   Pipeline-step timer (bash, no deps)
scripts/benchmark-app.sh        App boot + request loop wrapper
scripts/_bench-runner.mjs       Node:http loop (called by benchmark-app.sh)

benchmarks/pipeline-baseline.json   Sample baseline (machine-specific — replace with yours)
benchmarks/app-baseline.json        Same.
```
