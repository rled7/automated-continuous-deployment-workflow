# Test Strategy

This document describes the test pyramid for this project, what runs when, how to run each suite locally, and the thresholds enforced by CI.

---

## The test pyramid

```
         /\
        /  \        Mutation (test-suite quality)
       /────\
      /      \      Performance / load (k6 + baseline comparison)
     /────────\
    /          \    Smoke (post-deploy, black-box)
   /────────────\
  /              \  E2E — browser (Playwright, chromium)
 /────────────────\
/                  \ Integration (supertest, in-process, pg-mem)
/──────────────────\
       Unit          Unit (Jest, isolated, many)
```

| Layer | Tool | Speed | Count |
|---|---|---|---|
| Unit | Jest | Fast (~5 s) | Many |
| Integration | Jest + supertest + pg-mem | Medium (~15 s) | Moderate |
| E2E | Playwright (chromium) | Slow (~60 s) | Few |
| Smoke | Jest + axios | Fast (~10 s) | Few |
| Performance | k6 | Slow (~8 min) | 1 scenario |
| Mutation | Stryker | Very slow (~10–30 min) | On-demand |

---

## What runs when

### Every commit / pull request
- **Unit tests** (`npm run test:unit`) with coverage
- **Integration tests** (`npm run test:integration`)
- **Lint** (`npm run lint`)
- **OWASP Dependency-Check** (vulnerability scan)
- **Gitleaks** (secret scan)
- **SonarQube analysis** + quality gate
- **Trivy image scan** + **grype SBOM scan** (after Docker build)

### After staging deploy (develop branch only)
- **Smoke tests** (via `runSmokeTests('staging')` in the Jenkinsfile)
- **Performance tests** (k6 load test + baseline comparison)
- **E2E tests** (Playwright against `https://staging.app.${APP_NAME}.internal`)

### After production deploy (main branch)
- **Smoke tests** (via `runSmokeTests('production')`)

### Nightly (3 am UTC ± hash window) or on-demand
- **Mutation tests** (Stryker — triggered by cron or `RUN_MUTATION_TESTS=true` parameter)

---

## How to run each suite locally

### Unit tests
```sh
cd app
npm ci
npm run test:unit
```

### Integration tests
```sh
cd app
npm run test:integration
```

### Both (full Jest run with coverage)
```sh
cd app
npm test -- --coverage
```

### Lint
```sh
cd app
npm run lint
```

### E2E tests (requires a running app)
```sh
# Install browser (one-time per machine)
cd app
npm run test:e2e:install

# Start the app in one terminal
npm run dev

# Run E2E tests in another terminal (defaults to http://localhost:3000)
npm run test:e2e

# Or target a remote environment
BASE_URL=https://staging.my-app.internal npm run test:e2e
```

### Smoke tests
```sh
cd tests
npm ci
BASE_URL=http://localhost:3000 npm run test:smoke
```

### Performance tests (requires k6)
```sh
k6 run --out json=/tmp/k6-results.json \
  --env BASE_URL=http://localhost:3000 \
  tests/performance/load-test.js

# Compare against baseline
node tests/performance/compare-baseline.js \
  --current  /tmp/k6-results.json \
  --baseline tests/performance/baseline.json
```

See `docs/perf-baseline.md` for full details on the baseline workflow.

### Mutation tests
```sh
cd app
NODE_OPTIONS=--experimental-vm-modules npm run test:mutation
```

This is slow (10–30 minutes depending on source size). Run it locally when adding new source logic to verify the test suite catches mutations. Do not run it on every PR.

---

## Coverage thresholds

Enforced by Jest (`app/jest.config.js`) when `--coverage` is passed:

| Measure | Threshold |
|---|---|
| Lines | 80% |
| Branches | 70% |
| Functions | 60% |

Enforced by the Cobertura Jenkins plugin (`lineCoverageTargets: '80, 70, 60'`): healthy ≥ 80%, unstable < 70%, failure < 60%.

---

## Mutation score thresholds

Enforced by Stryker (`app/stryker.conf.json`):

| Level | Score |
|---|---|
| High (green) | ≥ 80% |
| Low (yellow) | 60–79% |
| Break (pipeline failure) | < 50% |

The `break: 50` threshold is conservative for an initial rollout. Once the team has a few mutation runs establishing a historical score, tighten `break` to 60 and `low` to 70.

A mutation score below 80% means more than 20% of the mutations injected into source code were **not** killed by the test suite — i.e. the tests passed even though the code was wrong. This indicates gaps in assertion coverage.

---

## Related files

- `app/jest.config.js` — Jest project configuration
- `app/playwright.config.js` — Playwright E2E configuration
- `app/stryker.conf.json` — Stryker mutation configuration
- `app/e2e/` — Playwright spec files
- `tests/smoke/smoke.test.js` — post-deploy smoke test
- `tests/performance/load-test.js` — k6 load scenario
- `tests/performance/baseline.json` — committed perf baseline
- `tests/performance/compare-baseline.js` — regression comparison script
- `docs/perf-baseline.md` — baseline workflow detail
- `Jenkinsfile` — CI/CD pipeline (stages: Test, E2E Tests, Performance Tests, Mutation Tests)
