# Tech Stack — Why Each Tool

Rationale for every major component in the pipeline. Originally part of the README; moved here in Build 023 to keep the README focused on "how do I use this?" rather than "why these choices?"

## CI/CD Orchestration

**Jenkins** — the core pipeline engine. Every `git push` triggers the full build → test → deploy → rollback sequence automatically. Chosen over GitHub Actions or GitLab CI because Jenkins is self-hosted (full control over secrets, no vendor lock-in), has a massive plugin ecosystem, and is the industry standard in enterprise DevOps environments.

GitHub Actions is added in Build 023 for *fast* PR feedback (lint + unit tests in <1 min); it does NOT replace Jenkins.

## Application Runtime

**Node.js 20 (LTS)** — lightweight, fast container startup, async I/O suits the API workload.

**Express.js** — minimal HTTP framework. Chosen over Fastify or NestJS for simplicity; the demo doesn't need an opinionated framework.

## Containerization

**Docker** — standard for container-based deployments.

**Multi-stage Dockerfile** — keeps the final image small. Build tools and dev deps live in earlier stages and get thrown away.

**Docker Compose** — local development infra (Jenkins, SonarQube, Postgres, Redis, registry) as a single stack.

## Container Orchestration

**Kubernetes** — pod scheduling, health checking, autoscaling, zero-downtime rolling updates.

**Kustomize (overlays)** — base + environment overlays for `production` and `staging`. Chosen over Helm (for the app manifests) because the app is a single service; Helm's templating overhead isn't worth it. Helm IS used for upstream platform components (Argo CD, cert-manager, kube-prometheus-stack, etc.).

**Argo CD (GitOps)** — reconciles cluster state from `k8s/overlays/{production,staging}` continuously. Chosen over push-based `kubectl apply` because: drift detection, automatic re-sync, declarative source of truth.

**Argo Rollouts** — canary deployments for production with automated metric-based promotion. Chosen over Flagger because Argo Rollouts integrates natively with Argo CD and uses the same Kustomize overlay.

## Code Quality & Security

**SonarQube** — static analysis with a quality gate that blocks the pipeline.

**OWASP Dependency Check** — scans `node_modules` against the NVD; fails on CVSS ≥ 7.

**Trivy** — Docker image vuln scan, fails on HIGH/CRITICAL.

**Grype** — secondary vuln scan against the syft-generated SBOM (different feed, complementary coverage).

**Gitleaks** — secret-scanning on every commit + every PR.

**Syft + Cosign** — CycloneDX SBOM generation + keyless image signing (Sigstore). Build 019 set up the full trust path.

**Kyverno** — admission policies (require resource limits, require labels, disallow privileged, disallow `:latest`, verify image signatures, etc.). Chosen over OPA/Gatekeeper because Kyverno's YAML-only policies are easier to audit; no Rego.

**ESLint** — JS linting at source level; runs both in pre-commit hook and in the GH Actions PR check.

## Testing

**Jest** — unit + integration test runner. JUnit XML for Jenkins, Cobertura coverage with 80% threshold.

**Supertest** — HTTP-level integration tests against a fresh Express app instance.

**Playwright** — E2E browser tests run against staging post-deploy.

**Stryker** — mutation testing (nightly / manual) measures test-suite quality, not just code coverage.

**k6** — load test post-deploy with baseline-comparison regression detection.

**Smoke tests (axios)** — fast post-deploy sanity checks.

## Infrastructure & Networking

**NGINX Ingress Controller** — cloud-agnostic L7 routing.

**cert-manager** — TLS cert lifecycle (Let's Encrypt prod/staging or self-signed for kind).

## Observability

**Prometheus** (kube-prometheus-stack) — metrics scraping + alert rules + recording rules + multi-window burn-rate SLO alerts.

**Grafana** — dashboards (auto-imported via sidecar from ConfigMaps).

**Alertmanager** — receivers + routing (PagerDuty for `severity: page`, Slack for `severity: warning`).

**Loki + Promtail** — log aggregation. pino JSON logs from app pods → Promtail DaemonSet → Loki.

**Tempo** — distributed traces. App's OpenTelemetry SDK → OTel Collector → Tempo.

**OpenTelemetry Collector** — central trace pipeline; receives OTLP/HTTP from app, forwards to Tempo.

**Pushgateway** — DORA metrics pushed from Jenkinsfile (deployment frequency, lead time, change failure rate, MTTR).

## Configuration & Secrets

**Jenkins Configuration as Code (JCasC)** — Jenkins server config in YAML.

**Sealed Secrets** — encrypted secret manifests committed to git; the controller's private key decrypts in-cluster.

**Kubernetes ConfigMaps** — non-sensitive config (Redis URL, log level, feature flags).

## Resilience

**Velero + MinIO** — namespace + cluster backups; MinIO is the local S3-compatible store (cloud should swap for native object storage).

**Chaos Mesh** — fault injection: pod kills, network delay/partition, CPU stress, IO delay. Game-day experiments live in `chaos/`.

## Notifications

**Slack (Jenkins plugin + Alertmanager)** — pipeline events, alert routing.

**PagerDuty (Alertmanager)** — `severity: page` and `severity: critical` alerts.

## Developer Experience

**Husky + lint-staged + commitlint + Prettier** — pre-commit hooks (Build 023). Lint and format only the staged files; validate the commit message against Conventional Commits.

**GitHub Actions** — fast PR validation (lint + unit tests, <1 min) running alongside the Jenkins pipeline.

**Dependabot** — weekly dependency updates for npm, docker, github-actions.

**Renovate** — alternative dependency manager (Dependabot is simpler; included in repo because it's free and configured by the standard `dependabot.yml`).
