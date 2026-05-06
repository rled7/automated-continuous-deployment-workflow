# Changelog

All notable file-level changes to this repo, tracked per build. Newest first.

## Build 014 — Argo CD app-of-apps bootstrap, sealed-secrets, nip.io for kind
**Date:** 2026-05-06
**Scope:** Phase A of the production-readiness plan (closes Phase A)

### Added

- `argocd/bootstrap/projects/platform.yaml` — `AppProject` named `platform`. Allows source repo + eight Helm chart repos (bitnami, jetstack, prometheus-community, argo-helm, grafana, opentelemetry, ingress-nginx, sealed-secrets). Destinations `*` (all namespaces in-cluster). `clusterResourceWhitelist: */*` so CRDs and ClusterIssuers can be managed.
- `argocd/bootstrap/root.yaml` — Root `Application` named `bootstrap`, project `platform`, source path `argocd/bootstrap/apps`, automated sync (prune + selfHeal), syncOptions `CreateNamespace=true` + `ApplyOutOfSyncOnly=true`.
- `argocd/bootstrap/apps/sealed-secrets.yaml` — Argo Application, chart `sealed-secrets` v2.16.2 from `https://bitnami-labs.github.io/sealed-secrets`, deployed to `kube-system`, sync wave -10. `fullnameOverride: sealed-secrets-controller`.
- `argocd/bootstrap/apps/ingress-nginx.yaml` — Argo Application, chart `ingress-nginx` v4.11.3 from `https://kubernetes.github.io/ingress-nginx`, deployed to `ingress-nginx`, sync wave -10. `controller.service.type=NodePort` with NodePorts 30080/30443 for kind; comment explains cloud LB swap.
- `argocd/bootstrap/apps/cert-manager.yaml` — Argo Application, chart `cert-manager` v1.16.3 from `https://charts.jetstack.io`, deployed to `cert-manager`, sync wave -10. `installCRDs: true`, `ServerSideApply=true`.
- `argocd/bootstrap/apps/cert-manager-issuers.yaml` — Argo Application, `directory` source pointing at `argocd/bootstrap/issuers/`, deployed to `cert-manager`, sync wave 0. Applies raw `ClusterIssuer` manifests after cert-manager CRDs are ready.
- `argocd/bootstrap/apps/argo-rollouts.yaml` — Argo Application, chart `argo-rollouts` v2.38.2 from `https://argoproj.github.io/argo-helm`, deployed to `argo-rollouts`, sync wave -10. `installCRDs: true`, dashboard enabled.
- `argocd/bootstrap/apps/kube-prometheus-stack.yaml` — Argo Application, chart `kube-prometheus-stack` v67.9.0 from `https://prometheus-community.github.io/helm-charts`, deployed to `monitoring`, sync wave 0. kind-tuned: `prometheus.prometheusSpec.resources.requests={cpu:100m,memory:256Mi}`, `grafana.adminPassword=changeme-bootstrap-only`, `nodeExporter.hostRootFsMount.enabled=false`, reduced retention (24h), `ServerSideApply=true`.
- `argocd/bootstrap/apps/loki-stack.yaml` — Argo Application, chart `loki` v6.24.0 from `https://grafana.github.io/helm-charts`, deployed to `monitoring`, sync wave 0. Single-binary mode, `replication_factor=1`, `storage.type=filesystem`, replicas=1.
- `argocd/bootstrap/apps/otel-collector.yaml` — Argo Application, chart `opentelemetry-collector` v0.111.0 from `https://open-telemetry.github.io/opentelemetry-helm-charts`, deployed to `monitoring`, sync wave 0. Mode `deployment`, OTLP/HTTP receiver on 4318. Exporter stubbed as `logging` (detailed verbosity) with a TODO comment to swap for an `otlp` exporter pointing at Grafana Tempo once Tempo is added to the stack.
- `argocd/bootstrap/issuers/selfsigned-issuer.yaml` — `ClusterIssuer` named `selfsigned-issuer` with `selfSigned: {}`. Used by kind/nip.io overlays. Comment explains when to use.
- `argocd/bootstrap/issuers/letsencrypt-staging.yaml` — `ClusterIssuer` for Let's Encrypt staging CA. For cloud deployments. Comment explains prerequisites and swap procedure.
- `argocd/bootstrap/issuers/letsencrypt-prod.yaml` — `ClusterIssuer` for Let's Encrypt production CA. Comment warns about rate limits and prerequisites.
- `argocd/bootstrap/README.md` — Full bootstrap guide: pre-reqs, kind cluster setup pointer, install Argo CD, apply AppProject + root, watch sync, apply my-app apps, seal secrets, access UIs, sync-wave table, notes on cloud swap.
- `k8s/secrets/my-app-secrets.template.yaml` — Template `SealedSecret` for keys `db-host` and `db-password`. Contains placeholder ciphertext with a prominent "DO NOT APPLY" header comment; instructs use of `seal-secret.sh`.
- `k8s/secrets/docker-registry-secret.template.yaml` — Template `SealedSecret` of type `kubernetes.io/dockerconfigjson`. Placeholder ciphertext; header explains the `kubectl create secret docker-registry | kubeseal` workflow.
- `k8s/secrets/README.md` — Sealed secrets directory guide: file table, seal workflow, 4 important notes (per-cluster keys, never commit plaintext, back up controller key, rotation).
- `scripts/seal-secret.sh` — Bash helper (`set -euo pipefail`). Args: `<namespace> <secret-name> <key=value>...`. Validates `kubectl` and `kubeseal` on PATH with clear errors. Builds a dry-run `Secret` YAML and pipes through `kubeseal --format=yaml --controller-namespace=kube-system`. Prints SealedSecret YAML to stdout.
- `docs/secrets.md` — Sealed Secrets guide: why sealed-secrets vs plain Secrets vs ESO (comparison table), how it works, sealing a new secret, rotation workflow, controller key backup, disaster recovery (restore key on new cluster).
- `docs/cluster-setup.md` — Local kind cluster setup guide: prerequisites table, inline `kind-config.yaml` with `extraPortMappings` (host 80→30080, host 443→30443), bootstrap order (kind up → Argo CD → root → my-app apps → seal secrets), how to access Argo CD/Grafana/app via nip.io, tear-down.

### Modified

- `k8s/overlays/staging/ingress-patch.yaml` — Host changed from `staging.app.yourdomain.com` to `staging.app.127.0.0.1.nip.io`; cluster-issuer changed from `letsencrypt-staging` to `selfsigned-issuer`. Comment block added explaining how to swap back for cloud deployments.
- `k8s/overlays/production/ingress-patch.yaml` — Host changed from `app.yourdomain.com` to `app.127.0.0.1.nip.io`; cluster-issuer changed from `letsencrypt-prod` to `selfsigned-issuer`. Comment block added explaining how to swap back for cloud deployments.
- `scripts/setup.sh` — Added `--bootstrap-argo` mode: installs Argo CD, waits for `argocd-server` rollout, applies `argocd/bootstrap/projects/platform.yaml` + `argocd/bootstrap/root.yaml`, prints follow-up steps (watch apps, apply my-app, seal secrets, port-forward UI). Updated usage comment at top.

### Closes (from production-readiness plan)
- Phase A: GitOps bootstrap layer (app-of-apps), sealed-secrets workflow, local kind cluster support with nip.io + self-signed TLS

### Judgment calls
- **OTel exporter:** stubbed as `logging` (detailed verbosity) instead of OTLP because Grafana Tempo is not yet installed. A TODO comment documents the exact config change needed when Tempo is added.
- **kube-prometheus-stack on kind:** `prometheus.prometheusSpec.resources.requests={cpu:100m,memory:256Mi}`, retention 24h, `nodeExporter.hostRootFsMount.enabled=false` (fails on some kind/containerd configs), `grafana.adminPassword=changeme-bootstrap-only`.
- **Loki:** single-binary mode with `storage.type=filesystem` (no object store) and `replication_factor=1`; bundled Grafana disabled (using kube-prometheus-stack's Grafana instead).
- **Chart versions pinned** (latest stable as of late 2025): sealed-secrets 2.16.2, ingress-nginx 4.11.3, cert-manager v1.16.3, argo-rollouts 2.38.2, kube-prometheus-stack 67.9.0, loki 6.24.0, opentelemetry-collector 0.111.0.

---

## Build 013 — Custom Jenkins agent image
**Date:** 2026-05-06
**Scope:** Phase B of the production-readiness plan

### Added

- `docker/jenkins-agent/Dockerfile` — custom agent image based on `jenkins/inbound-agent:latest-jdk17`. Bundles every CLI the Jenkinsfile invokes (node 20, kubectl, kustomize, kubeconform, gitleaks, syft, cosign, trivy, OWASP dependency-check, k6, gh) at pinned versions exposed as `ENV` vars. Final `RUN` is a sanity check that fails the build if any tool isn't on PATH.
- `docker/jenkins-agent/.dockerignore` — explicit `*` + `!Dockerfile` so the build context is just the Dockerfile.
- `docs/agent-image.md` — build / push / use guide; covers tagging, multi-arch caveats, docker-socket vs kaniko trade-off, image-size note, local sanity-check command.

### Modified

- `docker/jenkins/jenkins.yaml` — added a `jenkins.clouds.kubernetes` block with a `cicd-agent` pod template that references the custom image (placeholder `ghcr.io/YOUR_ORG/jenkins-cicd-agent:latest` — bump to a pinned tag in production). Pod template requests 500m/1Gi, limits 2/4Gi, mounts `/var/run/docker.sock` for the existing `docker.build` calls.
- `Jenkinsfile` — replaced top-level `agent any` with `agent { kubernetes { label 'cicd-agent', defaultContainer 'cicd' } }`. Removed the `tools { nodejs 'NodeJS-20' }` block — the custom agent has node baked in.

### Closes (from production-readiness plan)
- Phase B: tooling assumed on the Jenkins agent (every CLI now bundled in the image)

### Caveats
- Image is amd64-only; switch to `docker buildx build --platform linux/amd64,linux/arm64` if Jenkins runs on arm64.
- Docker socket is mounted; production should switch to kaniko or buildah and remove the mount.
- Image is large (~1.5 GB) — acceptable for CI agents, not for production workloads.

## Build 009 — Supply-chain hardening + manifest validation + release/PR-preview wiring
**Date:** 2026-05-06
**Scope:** Phase C, plan points 13, 15; wiring of points 18 and 29

### Added (Jenkinsfile stages)

- **`Gitleaks`** (parallel branch inside `Code Quality & Security`) — runs `gitleaks detect` in SARIF mode; `|| true` makes it warn-only initially; comment notes this should be tightened to fail on CRITICAL findings once a baseline suppression list is established. Archives `reports/gitleaks.sarif`. Closes plan point 13 (secret scanning).
- **`Validate Manifests`** (new top-level stage, after Build, before Test) — iterates every `k8s/overlays/*/` directory, renders each overlay with `kubectl kustomize`, and pipes through `kubeconform -strict -ignore-missing-schemas`. `-ignore-missing-schemas` is required because Argo Rollouts CRDs do not have schemas in the default kubeconform schema set. Archives `reports/kubeconform.txt`. Closes plan point 15 (manifest validation).
- **`Deploy → PR Preview`** (new top-level stage, between Test and Docker Build & Push) — runs only on pull-request builds (`changeRequest()` condition); calls `scripts/pr-preview-up.sh ${CHANGE_ID}` (added in Build 011) via `withCredentials([file(...kubeconfig...)])`; posts Slack notification with the preview URL on success. Comment explains that PR teardown (`scripts/pr-preview-down.sh`) lives in a separate Jenkins job triggered by the GitHub "pull_request closed" webhook. Wires plan point 29.
- **`Release`** (new top-level stage, at the end) — fires only when `buildingTag()` matches `v\d+\.\d+\.\d+`; re-tags the image with the SemVer tag and pushes it; creates a GitHub Release via `gh release create` wrapped in `withCredentials` for `github-credentials`; comment notes `gh` CLI must be available on the agent. Wires plan point 18 (completes the release-stage sketch from `docs/RELEASING.md` and `scripts/release.sh` added in Build 010).

### Modified (Jenkinsfile stages)

- **`Docker Build & Push`** — after `appImage.push()`: generates a CycloneDX SBOM with `syft "${FULL_IMAGE}" -o cyclonedx-json > reports/sbom.cdx.json`; signs the image keyless with `COSIGN_EXPERIMENTAL=1 cosign sign --yes "${FULL_IMAGE}"` (comment explains this requires a Fulcio + Rekor OIDC setup in production); archives `reports/sbom.cdx.json`. Closes plan point 13 (SBOM + image signing).

### Closes (from broader plan)
- Point 13: secret scanning (Gitleaks), SBOM generation (syft), image signing (cosign)
- Point 15: Kubernetes manifest validation (kubeconform)

### Wires (stages previously scripted in other builds, now live in Jenkinsfile)
- Point 18: Release stage — completes the sketch from `docs/RELEASING.md` (Build 010); uses `scripts/release.sh` flow of tag → Docker re-tag → GitHub Release
- Point 29: PR Preview stage — wires `scripts/pr-preview-up.sh` / `scripts/pr-preview-down.sh` added in Build 011; teardown job documented in comments

---

## Build 012 — SLO + DORA + OpenTelemetry
**Date:** 2026-05-06
**Scope:** Phase C, plan points 22, 23, 24

### Added

- `monitoring/prometheus.yaml` — third ConfigMap `prometheus-recording-rules` with two SLI recording rules: `http_requests:availability:ratio_rate5m` (non-5xx ratio) and `http_requests:latency:p95_5m` (P95 histogram); plus `slo-alerts.yaml` block inside `prometheus-rules` with multi-window multi-burn-rate alerts (`AvailabilitySLOFastBurn` at 14.4× / severity: page and `AvailabilitySLOSlowBurn` at 6× / severity: warning) against a 99.9% availability SLO.
- `monitoring/slo.yaml` — OpenSLO v1 `SLO` definitions for three objectives: 99.9% HTTP availability (30d), P95 latency < 500 ms (30d), 99% pod startups succeed within 60 s (30d).
- `monitoring/pushgateway.yaml` — Prometheus Pushgateway `Deployment` + `ClusterIP` `Service` in the `monitoring` namespace; scrapes DORA metrics pushed from Jenkinsfile stages.
- `docs/dora-metrics.md` — explains the four DORA metrics, Jenkinsfile push sketches for each, Prometheus scrape config addition, and PromQL / Grafana query examples.
- `docs/log-aggregation.md` — guide to shipping pino JSON logs to Loki via Promtail (DaemonSet, pipeline_stages, LogQL examples) and Vector (VRL remap transform, Loki sink config); includes comparison table.
- `app/src/lib/otel.js` — OpenTelemetry SDK initialisation module; no-op when `OTEL_EXPORTER_OTLP_ENDPOINT` is unset; configures `NodeSDK` with OTLP/HTTP exporter, auto-instrumentations (fs disabled), `Resource` from `OTEL_SERVICE_NAME` + `npm_package_version`; registers graceful `sdk.shutdown()` on SIGTERM/SIGINT without calling `process.exit`.

### Modified

- `app/package.json` — added six OTel dependencies: `@opentelemetry/api ^1.9.0`, `@opentelemetry/sdk-node ^0.57.0`, `@opentelemetry/auto-instrumentations-node ^0.56.0`, `@opentelemetry/exporter-trace-otlp-http ^0.57.0`, `@opentelemetry/resources ^1.30.0`, `@opentelemetry/semantic-conventions ^1.28.0`.
- `app/src/server.js` — added `import './lib/otel.js';` as the very first import (line 1), before all other imports, so auto-instrumentation patches libraries at load time.

### Closes (from broader plan)
- Point 22: SLO definitions + burn-rate alerting
- Point 23: DORA metrics infrastructure (Pushgateway + docs)
- Point 24: OpenTelemetry distributed tracing

---

## Build 011 — GitOps, progressive delivery, PR previews, local dev
**Date:** 2026-05-06
**Scope:** Phase C, plan points 17, 26, 27, 29

### Added

- `argocd/AppProject.yaml` — Argo CD `AppProject` named `my-app`; allows source repo `rled7/automated-continuous-deployment-workflow`; permits destinations for `production`, `staging`, and `preview-*` namespaces; grants `ci-deployer` role sync+get access.
- `argocd/Application-production.yaml` — Argo CD `Application` tracking `k8s/overlays/production`; automated sync with `prune: true` + `selfHeal: true`; `ignoreDifferences` for `Rollout.spec.replicas` to avoid HPA conflicts.
- `argocd/Application-staging.yaml` — same shape as production but tracks `k8s/overlays/staging` and deploys to the `staging` namespace.
- `argocd/README.md` — bootstrap guide: install Argo CD via kubectl, apply the manifests, access the UI, and overview of the application/namespace layout.
- `k8s/overlays/production/rollout-patch.yaml` — Argo `Rollout` resource replacing the base Deployment in production; canary strategy with steps: setWeight 25% → pause 2m → analysis → setWeight 50% → pause 2m → analysis → setWeight 100%.
- `k8s/overlays/production/analysis-template.yaml` — `AnalysisTemplate` named `success-rate`; queries Prometheus for HTTP 5xx error rate every 30 s; requires ≥ 0.99 success rate; fails after 3 consecutive failures.
- `k8s/overlays/production/deployment-removal.yaml` — strategic-merge patch with `$patch: delete` that removes the base `Deployment/my-app` from the production overlay so the Rollout can take over as workload controller.
- `scripts/pr-preview-up.sh` — creates namespace `preview-pr-<PR_NUMBER>`, labels it, builds the staging kustomize overlay, rewrites namespace via `sed`, and applies into the preview namespace; `set -euo pipefail`.
- `scripts/pr-preview-down.sh` — deletes namespace `preview-pr-<PR_NUMBER>` and all resources within it; idempotent (no-op if namespace doesn't exist).
- `docs/pr-preview.md` — explains the PR preview flow, namespace lifecycle table, Argo CD scoping, manual usage, Jenkinsfile stage sketch (Build 009 will wire in), and limitations/future improvements.
- `skaffold.yaml` — Skaffold v4beta11 config: builds `my-app` image from `app/` with `docker/Dockerfile`, deploys staging overlay via kustomize, hot-syncs `app/src/**/*.js` changes into running container, port-forwards service port 3000 → localhost:3000.
- `docs/local-dev.md` — local dev guide: prerequisites table, quick-start commands, Skaffold command reference, file-sync hot-reload explanation, Skaffold vs Argo CD inner-loop/outer-loop comparison.

### Modified

- `k8s/overlays/production/kustomization.yaml` — added `rollout-patch.yaml` and `analysis-template.yaml` as resources; added `deployment-removal.yaml` as a `$patch: delete` strategic-merge patch targeting `Deployment/my-app`.

### Kustomize technique for Rollout vs Deployment swap

A `deployment-removal.yaml` strategic-merge patch with `$patch: delete` is applied via the `patches` stanza targeting `kind: Deployment, name: my-app`. This removes the base Deployment from the production manifest stream. `rollout-patch.yaml` is then added as a standalone resource. This avoids requiring `kustomize` to understand Argo Rollout CRDs and keeps both files clearly separated.

### Closes (from broader plan)
- Point 17: local dev loop (Skaffold)
- Point 26: Argo CD GitOps setup
- Point 27: Argo Rollouts canary progressive delivery
- Point 29: PR preview environments

---

## Build 010 — repo governance + automation
**Date:** 2026-05-06
**Scope:** Phase C, plan points 14, 16, 18, 25

### Added

- `.github/CODEOWNERS` — default reviewer `@rled7`; explicit ownership for `Jenkinsfile`, `docker/`, `k8s/`, `monitoring/`, `scripts/` (platform team placeholder) and `app/`, `tests/` (app team placeholder).
- `.github/PULL_REQUEST_TEMPLATE.md` — standardised PR template: Summary, Changes, Test plan checklist, Risk + rollback plan, Linked issues, Screenshots section.
- `.github/ISSUE_TEMPLATE/bug.md` — bug-report template with frontmatter (`name`, `about`, `labels: bug`) and sections for description, reproduction steps, expected/actual behaviour, environment, and additional context.
- `.github/ISSUE_TEMPLATE/feature.md` — feature-request template with frontmatter (`name`, `about`, `labels: enhancement`) and sections for problem, proposed solution, alternatives, and acceptance criteria.
- `SECURITY.md` — vulnerability disclosure policy: supported versions table, private reporting via GHSA or email, response timeline (acknowledge 48h, fix critical in 7 days), and coordinated disclosure commitment.
- `CONTRIBUTING.md` — concise contributor guide: setup (references `scripts/setup.sh`), branch model (`feature/* → develop → main`), Conventional Commits style, PR process, test commands with coverage thresholds, and code-review norms.
- `docs/runbook.md` — operational runbook: quick links (Jenkins, Grafana, Slack, on-call), alert playbooks for all four Prometheus alerts (`HighErrorRate`, `HighResponseTime`, `AppDown`, `PodRestartingFrequently`), automatic and manual rollback procedures, hotfix procedure, escalation matrix, and production-access policy.
- `docs/RELEASING.md` — release flow guide: SemVer overview, `scripts/release.sh` usage, manual release steps, Jenkinsfile release stage sketch (not yet live), changelog and hotfix release notes.
- `.github/dependabot.yml` — weekly Dependabot updates for `npm` (`/app`, `/tests`), `docker` (`/docker`), and `github-actions` (`/`); minor+patch updates grouped per ecosystem.
- `scripts/release.sh` — release helper: validates `MAJOR.MINOR.PATCH` version argument, bumps `app/package.json` via `node -e`, commits `chore(release): vX.Y.Z`, creates annotated tag; prints `git push --follow-tags` for manual review before push.

### Closes (from broader plan)
- Point 14: CODEOWNERS + PR / issue templates
- Point 16: SECURITY.md + CONTRIBUTING.md
- Point 18: operational runbook
- Point 25: Dependabot + release script

---

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

---

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

---

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

---

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

---

## Build 004 — Code-bug fixes
**Date:** 2026-05-05
**Scope:** Phase A, Batch 2b (original steps 7, 8, 9)

### Modified
- `app/src/server.js` — declare `server` before registering signal handlers; add `SHUTDOWN_TIMEOUT_MS` (55s) forced-exit guard so a stuck `server.close()` can't hang the pod past `terminationGracePeriodSeconds`; explicit `process.exit(0|1)` in the close callback; also handle SIGINT for parity with local dev.
- `docker/Dockerfile` — fix `CMD` JSON-form: `CMD [\"node\", \"dist/server.js\"]` had literal backslashes that would break container startup → now `CMD ["node", "dist/server.js"]`.
- `docker/Dockerfile` — `HEALTHCHECK` path mismatch: was hitting `/health` but the app exposes `/health/live` and `/health/ready` (matching the k8s probes) → now hits `/health/live`.

---

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

---

## Build 002 — Hygiene basics
**Date:** 2026-05-05
**Scope:** Phase A, Task 2

### Added
- `.gitignore`
- `.env.example`

### Untracked (kept on disk, removed from git)
- `app/node_modules/`
- `app/dist/`

---

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
