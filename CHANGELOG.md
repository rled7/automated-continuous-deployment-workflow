# Changelog

All notable file-level changes to this repo, tracked per build.

## Build 001 — File layout cleanup
**Date:** 2026-05-05
**Scope:** Phase A, Task 1

### Renamed
- `README` → `README.md`

### Moved
- `Load test.js` → `tests/performance/load-test.js`
- `Smoke.test` → `tests/smoke/smoke.test.js`
- `Prometheus` → `monitoring/prometheus.yaml`
- `Jenkins` → `docker/jenkins/jenkins.yaml` (JCasC config; referenced by docker-compose volumes)

### Deleted (redundant draft)
- `Deployment` (content merged into `k8s/production/deployment.yaml`)
- `Docker compose` (content merged into `docker/docker-compose.yml`)
- `DockerFile` (duplicate of `docker/Dockerfile`; only whitespace difference)
- `Setup` (content merged into `scripts/setup.sh`)

### Merged content
- `Deployment` → `k8s/production/deployment.yaml`: merged Namespace resource, Deployment labels/annotations, topologySpreadConstraints, terminationGracePeriodSeconds, imagePullPolicy, env vars (NODE_ENV, PORT, DB_HOST, DB_PASSWORD, REDIS_URL), startupProbe, securityContext, volumeMounts/volumes, imagePullSecrets, HPA memory metric, Service resource, Ingress resource; kept stray's `memory: "256Mi"` request and probe timings (initialDelaySeconds: 15, periodSeconds: 20) as the more production-ready values.
- `Docker compose` → `docker/docker-compose.yml`: merged container_name, restart policies, privileged/user settings, Jenkins JCasC env vars and volume mounts, sonarqube lts-community image with postgres backend (sonar-db), sonarqube_logs volume, registry_data volume, app-db service, redis service, cicd network definition.
- `Setup` → `scripts/setup.sh`: replaced minimal stub with full production script including set -euo pipefail, prerequisites check, .env loading, docker-compose pull + readiness wait, full Kubernetes namespace/secret/monitoring setup, and npm ci step.

## Build 002 — Hygiene basics
**Date:** 2026-05-05
**Scope:** Phase A, Task 2

### Added
- `.gitignore`
- `.env.example`

### Untracked (kept on disk, removed from git)
- `app/node_modules/`
- `app/dist/`

## Build 003 — Close gaps opened by Build 001 merges
**Date:** 2026-05-05
**Scope:** Phase A, Batch 2a

### Added
- `docker/jenkins/plugins.txt` — referenced by `docker-compose.yml` volume mount but didn't exist; now contains the standard pipeline + JCasC + k8s + SonarQube + Slack plugin set.
- `k8s/production/configmap.yaml` — `my-app-config` ConfigMap was referenced by `deployment.yaml` (`REDIS_URL` via `configMapKeyRef`) but never defined.
- `k8s/staging/deployment.yaml` — Jenkinsfile applies `k8s/${namespace}/` on the develop branch; staging directory didn't exist. Includes Namespace, Deployment (1 replica), ConfigMap, Service, and Ingress (with `letsencrypt-staging` issuer).

### Modified
- `.env.example` — aligned env var names with what `scripts/setup.sh` actually reads:
  - Renamed `DOCKER_REGISTRY_URL` → `DOCKER_REGISTRY`
  - Added `DOCKER_USER`, `DOCKER_PASSWORD`, `JENKINS_ADMIN_PASSWORD`, `SLACK_TOKEN`, `SLACK_WORKSPACE`, `DB_HOST`, `DB_PASSWORD`
  - Defaulted `SONAR_HOST_URL` to `http://localhost:9000` for local dev

## Build 007 — Jenkinsfile bug fixes
**Date:** 2026-05-05
**Scope:** Phase B, plan point 4 (Jenkinsfile correctness)

### Fixed

1. **`getEnvironment()` in `environment {}` block (line 14 → Checkout stage)** — moved `env.ENV = getEnvironment()` into a `script {}` block inside the Checkout stage to avoid mixing Groovy function calls with declarative env var assignments, which can produce surprising evaluation order issues.

2. **`runSmokeTests()` missing `npm ci` (line 299)** — added `npm ci --prefer-offline --no-audit --no-fund` before `npm run test:smoke` so the standalone `tests/` package's dependencies are always installed before the runner executes.

3. **Missing `reports/` directories (Lint, Unit Tests, Integration Tests, Dependency Scan, Performance Tests)** — added `mkdir -p reports` (or `mkdir -p reports/dependency-check`) at the top of each affected `sh` block so the first run never fails due to a missing output directory.

4. **No `tools {}` block** — added `tools { nodejs 'NodeJS-20' }` at the top level so `npm`/`node` (from the JCasC-defined `NodeJS-20` installation) are on PATH for the agent without requiring manual PATH manipulation.

5. **Redundant `KUBECONFIG_CRED` in environment block (line 8)** — removed the top-level `KUBECONFIG_CRED = credentials('kubeconfig')` entry; kubeconfig is already fetched via `withCredentials` inside `deployToKubernetes()`, which is more idiomatic and properly scoped.

6. **`NODE_OPTIONS=--experimental-vm-modules` for test scripts** — verified that `app/package.json` `test:unit` and `test:integration` scripts already include `NODE_ENV=test NODE_OPTIONS=--experimental-vm-modules` (set in Build 006). No Jenkinsfile change needed.

7. **`docker.withRegistry` double-scheme (line 164)** — normalized the registry URL with `.replaceFirst(/^https?:\/\//, '')` before prefixing `https://`, preventing `https://https://...` if the `docker-registry-url` credential value already contains a scheme.

8. **`pollSCM` missing webhook context** — replaced the inline comment with a fuller explanation noting that `pollSCM` is a safety-net fallback for environments where GitHub webhooks cannot reach Jenkins (e.g. local or firewalled installs) and will rarely fire in production.

9. **`runSmokeTests()` fragile `cd tests` (line 299)** — replaced `sh "cd tests && ..."` with a `dir('tests') { sh ... }` block so the working directory is set robustly by Jenkins regardless of what stage previously ran.

10. **Slack `slackSend` credential** — verified that `slackSend` relies on the global Slack notifier config (set via JCasC `slackNotifier.tokenCredentialId` in Build 003's `jenkins.yaml`). No code change needed.

### Closes (from broader plan)
- Point 4: Jenkinsfile bug fixes

## Build 006 — Test infrastructure
**Date:** 2026-05-05
**Scope:** Phase B, plan point 3 (real test infrastructure)

### Added
- `app/jest.config.js` — Jest config for native ESM (`transform: {}`); `testMatch` targets `src/__tests__/**/*.test.js`; coverage from `src/**/*.js` excluding test dirs; `coverageReporters: ['text', 'cobertura']`; thresholds: 80% lines, 70% branches, 60% functions.
- `app/.eslintrc.json` — minimal ESLint config: `env: {node, es2022, jest}`, `extends: ['eslint:recommended']`, `parserOptions: {ecmaVersion: 'latest', sourceType: 'module'}`.
- `app/src/__tests__/unit/health.test.js` — supertest-based tests for `GET /health/live` (200 + `{status:'alive'}`) and `GET /health/ready` (200 default; 503 after `setShuttingDown(true)`).
- `app/src/__tests__/unit/requestId.test.js` — tests that middleware passes through `x-request-id` header when present; generates UUID otherwise; sets both `req.id` and response header.
- `app/src/__tests__/unit/error.test.js` — tests ZodError → 400, `err.statusCode` preservation, 500 fallback, and `{error:{message,requestId}}` response shape.
- `app/src/__tests__/integration/api.test.js` — full-stack integration: `GET /api/items` 200+array; `POST /api/items` 201 valid / 400 invalid; `GET /metrics` 200 with prom-client content-type; `GET /health/live` 200.
- `tests/package.json` — standalone package for smoke-test stage: `jest ^29.7.0`, `jest-junit ^16.0.0`, `axios ^1.7.2`, `@jest/globals ^29.7.0`; `test:smoke` script matches Jenkinsfile invocation.

### Modified
- `app/package.json` — added `devDependencies`: `jest-junit ^16.0.0`, `supertest ^7.0.0`, `eslint ^8.57.0`, `eslint-plugin-jest ^27.9.0`, `@jest/globals ^29.7.0`; updated `test`/`test:unit`/`test:integration` scripts to prepend `NODE_ENV=test NODE_OPTIONS=--experimental-vm-modules` for native ESM support and to suppress pino-pretty in test runs.
- `app/src/lib/logger.js` — changed pino-pretty guard from `NODE_ENV !== 'production'` to `NODE_ENV === 'development'` so test runs (and CI) use JSON transport without requiring pino-pretty as a dev dependency.

### Notes
- `server.js` export refactor was already present (pre-authorized scope expansion from Build 005): `app` and `start()` are exported separately; `app.listen()` is only called when `import.meta.url` matches `process.argv[1]`.
- Jest ran locally: 12 unit tests pass, 6 integration tests pass (18 total). `--listTests` lists all 4 suites correctly.

### Closes (from broader plan)
- Point 3: real test infrastructure (unit, integration, smoke scaffolding)

## Build 008 — Kustomize overlay refactor
**Date:** 2026-05-06
**Scope:** Phase C, plan point 28
**Note:** Generated by a worktree-isolated Sonnet agent that forked from `main` instead of our branch tip. Files were ported manually onto the branch by the reviewer; the Jenkinsfile change was re-applied to the post-Build 007 state. No content was lost.

### Restructured
- `k8s/production/deployment.yaml`, `k8s/production/configmap.yaml`, `k8s/staging/deployment.yaml` (the previous duplicated layout) are removed.
- New layout:
  ```
  k8s/
  ├── base/                       (shared resources)
  │   ├── deployment.yaml
  │   ├── service.yaml
  │   ├── ingress.yaml
  │   ├── configmap.yaml
  │   ├── hpa.yaml
  │   ├── pdb.yaml
  │   └── kustomization.yaml
  └── overlays/
      ├── production/             (replicas=3, prod hostnames, letsencrypt-prod, info logs)
      └── staging/                (replicas=1, staging hostnames, letsencrypt-staging, debug logs)
  ```

### Modified
- `Jenkinsfile` — `deployToKubernetes()` now uses `kustomize edit set image my-app=${image}` + `kubectl apply -k .` instead of `sed`+`kubectl apply -f`.

## Build 005 — App middleware + observability
**Date:** 2026-05-05
**Scope:** Phase B, observability + hardening (plan points 11, 12, 19, 20, 21)

### Added
- `app/src/lib/logger.js` — pino logger; pretty-prints in development, JSON in production; honours `LOG_LEVEL` env var (default `info`).
- `app/src/lib/metrics.js` — prom-client `Registry` with default metrics enabled; exports `register` and `httpRequestDurationMicroseconds` histogram (labels: `method`, `route`, `status_code`).
- `app/src/middleware/requestId.js` — reads `x-request-id` header or generates a UUID via `crypto.randomUUID()`; sets `req.id` and echoes header back to client.
- `app/src/middleware/error.js` — centralised error handler; ZodError → 400 with issues list; `err.statusCode` preserved; fallback 500; logs via pino with `req.id`.
- `app/src/middleware/metrics.js` — records HTTP request duration into the histogram on `res.finish`.
- `app/package.json` dependencies: `prom-client ^15`, `pino ^9`, `pino-http ^10`, `helmet ^8`, `express-rate-limit ^7`, `zod ^3.23`.

### Modified
- `app/src/server.js` — full middleware stack: helmet, JSON parser, requestId, pino-http, metrics, rate-limiter (100 req/min, skips `/health/*` and `/metrics`); Zod-validated `POST /api/items`; `GET /metrics` endpoint serving prom-client output; real graceful shutdown: flip `setShuttingDown(true)` → wait 5s for readiness probes to observe 503 → `server.close()` → 55s forced-exit guard.
- `app/src/routes/health.js` — exports `setShuttingDown` setter; `GET /health/ready` returns 503 during shutdown and checks stubbed `checkDatabase`/`checkRedis` helpers (structured for easy replacement with real async calls); `/health/live` unchanged.

### Closes (from broader plan)
- Point 11: structured logging (pino)
- Point 12: Prometheus metrics endpoint
- Point 19: security headers (helmet)
- Point 20: rate limiting (express-rate-limit)
- Point 21: request validation (zod)

## Build 004 — Code-bug fixes
**Date:** 2026-05-05
**Scope:** Phase A, Batch 2b (original steps 7, 8, 9)

### Modified
- `app/src/server.js` — declare `server` before registering signal handlers; add `SHUTDOWN_TIMEOUT_MS` (55s) forced-exit guard so a stuck `server.close()` can't hang the pod past `terminationGracePeriodSeconds`; explicit `process.exit(0|1)` in the close callback; also handle SIGINT for parity with local dev.
- `docker/Dockerfile` — fix `CMD` JSON-form: `CMD [\"node\", \"dist/server.js\"]` had literal backslashes that would break container startup → now `CMD ["node", "dist/server.js"]`.
- `docker/Dockerfile` — `HEALTHCHECK` path mismatch: was hitting `/health` but the app exposes `/health/live` and `/health/ready` (matching the k8s probes) → now hits `/health/live`.
