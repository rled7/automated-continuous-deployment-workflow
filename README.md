# Automated Continuous Deployment Workflow

[![PR Checks](https://github.com/rled7/automated-continuous-deployment-workflow/actions/workflows/pr-checks.yml/badge.svg)](https://github.com/rled7/automated-continuous-deployment-workflow/actions/workflows/pr-checks.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Node](https://img.shields.io/badge/node-20%20LTS-339933?logo=node.js&logoColor=white)](./app/package.json)
[![OpenAPI](https://img.shields.io/badge/OpenAPI-3.0.3-6BA539?logo=openapiinitiative&logoColor=white)](./app/openapi.yaml)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-FE5196?logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org)

Production-grade Jenkins-based CI/CD pipeline for a Node.js Express app. **GitOps** with Argo CD, **progressive delivery** via Argo Rollouts, full **observability** (metrics + logs + traces), **supply-chain hardening** (SBOM + cosign + multi-arch), automated **cluster security** (Kyverno), **backups** (Velero), and **chaos engineering** (Chaos Mesh). Designed to run end-to-end on a local kind cluster — no cloud spend required.

## What's in the box

**Application** — Node 20 / Express / Postgres / Redis / OpenTelemetry. Helmet security headers, request-ID middleware, structured pino JSON logging, prom-client metrics, Zod request validation, per-IP rate limiting, real graceful shutdown (readiness flip → 5 s drain → DB pool drain → Redis close → server.close → exit). 19 Jest unit + integration tests, k6 load test with baseline regression detection, Playwright E2E, Stryker mutation testing. OpenAPI 3.0 spec served at `GET /openapi.yaml`.

**Pipeline (Jenkins, 15 stages)** — Checkout → SonarQube + OWASP DC + ESLint + Gitleaks (parallel) → Build → kubeconform manifest validation → Jest (parallel) → PR-preview deploy → multi-arch image build + Trivy + syft SBOM + cosign keyless sign + SLSA attest → grype SBOM scan → knex migrate → staging deploy → k6 perf vs baseline → Playwright E2E → Stryker (nightly) → manual gate → Argo Rollouts canary → DORA metric push → on-failure auto-rollback → tagged GitHub Release.

**GitOps + cluster** — Argo CD app-of-apps installs ingress-nginx, cert-manager (+ self-signed / LE-staging / LE-prod issuers), kube-prometheus-stack, Loki, Tempo, Promtail, OTel Collector, Pushgateway, Argo Rollouts, Kyverno, Velero, MinIO, Chaos Mesh, Dex, oauth2-proxy. Kustomize overlays for `production` and `staging`; per-PR preview namespaces.

**Security** — 9 Kyverno admission policies (resource limits, labels, read-only rootFS, no `:latest`, no host namespaces, no privileged, dangerous-cap blocklist, pod probes, image-signature verification). Default-deny `NetworkPolicy` + explicit allow rules. Pod Security Standards `restricted` enforcement. Sealed Secrets workflow. Edge auth via Dex (OIDC) + oauth2-proxy. Pre-commit gitleaks + commitlint. Dependabot weekly updates. Branch protection codified in `scripts/setup-branch-protection.sh`.

**Observability** — Prometheus scrape (15 s) + Alertmanager routing (PagerDuty for `severity: page/critical`, Slack for `severity: warning`) + Grafana with 4 auto-imported dashboards (app-overview, slo, dora, pipeline) + multi-window burn-rate SLO alerts (99.9 % availability target, P95 < 500 ms latency). Loki via Promtail DaemonSet. Tempo OTLP receiver. DORA metrics (deploy frequency, lead time, change failure rate, MTTR) pushed from Jenkinsfile.

**Resilience** — Velero daily backups of `production` + `staging` to MinIO (swappable to S3/GCS/Azure Blob). Chaos Mesh experiments: pod-failure, network-delay, network-partition, CPU-stress, IO-delay (staging only). DR runbook with quarterly drill checklist + RPO 24 h / RTO 1 h targets.

**Developer experience** — `Makefile` for every common command. `.devcontainer/` for one-click VS Code setup. Husky + lint-staged + commitlint + Prettier pre-commit. Two-pipeline PR feedback (GH Actions for fast lint+unit, Jenkins for full pipeline). `scripts/check-repo.sh` static validation; `scripts/production-checklist.sh` pre-flight gate.

---

## Architecture

```mermaid
graph TD
  Dev[Developer] -->|git push| GH[GitHub]
  GH -->|webhook| GHA[GH Actions: lint + unit tests]
  GH -->|webhook| Jenkins[Jenkins Pipeline]

  subgraph "Jenkins pipeline"
    Jenkins --> SAST[SonarQube + OWASP + Gitleaks + ESLint]
    SAST --> Build[npm build]
    Build --> Validate[kubeconform: validate k8s manifests]
    Validate --> Test[Jest unit + integration]
    Test --> ImgBuild[buildx multi-arch + Trivy + syft SBOM + cosign sign + grype]
    ImgBuild --> DeployS[Deploy → staging]
    DeployS --> E2E[Playwright E2E + k6 perf vs baseline]
    E2E --> Approve{Manual gate}
    Approve --> DeployP[Deploy → production]
    DeployP --> DORA[Push DORA metrics]
  end

  Jenkins -->|push image| Reg[Container Registry]
  GH -->|reconcile| Argo[Argo CD]
  Argo -->|sync| Cluster[(Kubernetes Cluster)]
  Reg -->|pull| Cluster

  subgraph "Cluster"
    Cluster --> Rollout[Argo Rollouts: canary 25→50→100]
    Rollout --> AppPods[my-app pods]
    AppPods -->|metrics| Prom[Prometheus]
    AppPods -->|logs| Promtail[Promtail] --> Loki
    AppPods -->|traces OTLP| Otel[OTel Collector] --> Tempo
    Prom --> Grafana
    Loki --> Grafana
    Tempo --> Grafana
    Prom --> AM[Alertmanager] -->|page| PD[PagerDuty]
    AM -->|warn| Slack
    Kyverno[Kyverno admission] -.policies.-> Cluster
    Velero -->|daily backup| MinIO[MinIO / S3]
    Chaos[Chaos Mesh] -.staging only.-> AppPods
  end

  DORA -->|push| PG[Pushgateway] --> Prom
```

The full stage list lives in [`Jenkinsfile`](./Jenkinsfile). Tech-stack rationale is in [`docs/tech-stack.md`](./docs/tech-stack.md).

---

## Run the app locally (no cluster, ~30 seconds)

For just verifying the app boots without standing up a cluster:

```bash
cd app && npm install
DB_FAKE=1 REDIS_FAKE=1 npm start
# then in another terminal:
curl http://localhost:3000/health/live           # → 200 {"status":"alive"}
curl http://localhost:3000/health/ready          # → 200 with stub checks
curl http://localhost:3000/api/items             # → 200 []
curl -X POST -H 'Content-Type: application/json' \
     -d '{"name":"hello"}' http://localhost:3000/api/items  # → 201
curl -s http://localhost:3000/metrics | head     # → prom-client metrics
```

`DB_FAKE`/`REDIS_FAKE` route the data layer to in-memory stubs so you can run without Postgres or Redis. For the full local stack (real DB + Redis + Jenkins + SonarQube + registry) use `make up` (docker-compose).

Run the test suite:

```bash
cd app && npm test       # 19 tests pass in ~3s
```

Or use the Makefile shortcuts (see `make help` for the full list):

```bash
make install        # install root + app dev deps (also installs husky hooks)
make dev            # local hot-reload server
make test           # unit + integration
make test-e2e       # Playwright E2E (needs running app or BASE_URL)
make build          # build the production Docker image
make up / make down # docker-compose stack (Jenkins + Sonar + Postgres + Redis + ...)
make kind-up        # spin up local kind cluster
make bootstrap      # apply Argo CD platform Apps to current cluster
make check          # static validation (ESLint + Jest discovery + bash -n + YAML + kubeconform + gitleaks)
```

VS Code users: open the repo, click **Reopen in Container** when prompted — `.devcontainer/devcontainer.json` provisions every CLI (kubectl, kind, kubeseal, helm, kustomize, skaffold, trivy, cosign, syft, gh, node 20). See [`.devcontainer/README.md`](./.devcontainer/README.md).

---

## API surface

| Method · Path | Returns | Auth | Used for |
|---|---|---|---|
| `GET /health/live` | `200 {"status":"alive"}` | open | Kubernetes `livenessProbe` |
| `GET /health/ready` | `200` healthy / `503` not ready | open | Kubernetes `readinessProbe`; flips to 503 during shutdown drain or when DB/Redis fail |
| `GET /api/items` | `200` array of `{id,name,created_at}` | OIDC (cloud) | Lists 100 most-recent rows |
| `POST /api/items` | `201 {id,name,created_at}` / `400` validation / `429` rate-limit | OIDC (cloud) | Body `{"name": string<=100}`; Zod-validated |
| `GET /metrics` | `200` Prometheus text format | open | `prom-client` defaults + `http_request_duration_ms` histogram (104 series) |
| `GET /openapi.yaml` | `200 application/yaml` | open | Machine-readable API contract |

Every response includes `x-request-id`, helmet security headers (CSP, HSTS, X-Content-Type-Options, etc.), and rate-limit headers (`RateLimit-Limit: 100`, `RateLimit-Remaining`, `RateLimit-Reset`). Full schemas + examples in [`app/openapi.yaml`](./app/openapi.yaml). Behavior contract pinned by 19 Jest tests in `app/src/__tests__/`.

---

## Daily developer flow

How a contributor uses this pipeline day-to-day:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  make install                              first-time only                   │
│  make dev      OR  skaffold dev            local hot-reload (laptop / kind)  │
│                                                                              │
│  edit files → save → pre-commit hook fires:                                  │
│     · ESLint --fix on staged JS                                              │
│     · Prettier --write on staged JSON/MD/YAML                                │
│     · gitleaks protect --staged   (secret scan)                              │
│     · commitlint                  (Conventional Commits format)              │
│                                                                              │
│  git push origin feature/foo                                                 │
│  gh pr create --base develop                                                 │
│                                                                              │
│  ──> GH Actions: lint + 19 unit/integration tests           ~30–60 s         │
│  ──> Jenkins:    full pipeline (15 stages, see below)       ~10–25 min       │
│        └─ Deploy → PR Preview namespace `preview-pr-N`                       │
│                                                                              │
│  PR merged to develop  →  staging deploy + smoke + perf vs baseline + E2E    │
│  PR merged to main     →  manual gate                                        │
│                              ↓                                               │
│                          Argo Rollouts canary 25% → 50% → 100%               │
│                          (Prometheus AnalysisTemplate gates each step)       │
│                                                                              │
│  Rollback on failure   →  auto: kubectl set image to previous revision       │
│                              + push change_failure_total to Pushgateway      │
│                                                                              │
│  Tag a release          →  git tag v1.2.3 && git push --follow-tags          │
│                              → Jenkins re-tags image + creates GH Release    │
└─────────────────────────────────────────────────────────────────────────────┘
```

To plug a new app into this pipeline (instead of the included Express demo):
1. Replace `app/src/` with your service.
2. Update `app/openapi.yaml` to match.
3. Update `app/migrations/` if your schema differs.
4. Adjust `app/jest.config.js` thresholds + test files.
5. Update `app/package.json` deps + scripts (`build`, `start`, `migrate`).
6. Update `docker/Dockerfile` if your runtime differs from Node 20.
7. The rest of the pipeline (Jenkins, Argo CD, Kubernetes manifests, monitoring, Kyverno, Velero, Chaos Mesh, edge auth) is service-agnostic.

End-to-end demo run with annotations: [`docs/demo.md`](./docs/demo.md). Pre-commit hook lifecycle: [`docs/dev-experience.md`](./docs/dev-experience.md).

## Quick start (local kind, ~5 minutes)

```bash
# 1. Spin up a local cluster (config exposes 80/443 to host)
kind create cluster --config docs/kind-config.yaml   # see docs/cluster-setup.md for the inline config

# 2. Bootstrap the platform via Argo CD (installs ingress-nginx, cert-manager,
#    sealed-secrets, kube-prometheus-stack, loki, tempo, promtail, otel-collector,
#    kyverno, argo-rollouts, velero, minio, chaos-mesh).
./scripts/setup.sh --bootstrap-argo

# 3. Wait for sync (~2-3 min on first run)
kubectl get applications -n argocd -w

# 4. Apply the my-app overlays
kubectl apply -f argocd/AppProject.yaml
kubectl apply -f argocd/Application-staging.yaml
kubectl apply -f argocd/Application-production.yaml

# 5. Seal real secrets (replace values first)
./scripts/seal-secret.sh production my-app-secrets \
    db-host=app-db.production.svc.cluster.local \
    db-password=changeme | kubectl apply -f -

# 6. Visit the app
open http://app.127.0.0.1.nip.io
```

Detailed walkthrough in [`docs/cluster-setup.md`](./docs/cluster-setup.md) and [`docs/local-dev.md`](./docs/local-dev.md).

---

## Pipeline at a glance

| # | Stage | What it does | Fails pipeline? |
|---|---|---|---|
| 1 | Checkout | Pulls code, sets `env.ENV` | Yes |
| 2 | Code Quality & Security (parallel) | SonarQube + OWASP DC (CVSS≥7) + ESLint + Gitleaks | Yes (except lint) |
| 3 | Build | `npm ci && npm run build` | Yes |
| 4 | Validate Manifests | `kubeconform` against every Kustomize overlay | Yes |
| 5 | Test (parallel) | Jest unit + integration | Yes |
| 6 | Deploy → PR Preview | Per-PR namespace via `scripts/pr-preview-up.sh` | Yes (PR builds only) |
| 7 | Docker Build & Push | `buildx` multi-arch → Trivy → push → syft SBOM → cosign sign → SLSA attest | Yes |
| 8 | Scan SBOM | `grype --fail-on high` against the SBOM | Yes |
| 9 | Migrate | `knex migrate:latest` Job in target namespace | Yes |
| 10 | Deploy → Staging | Kustomize → `kubectl apply -k` (develop branch) | Yes |
| 11 | Performance Tests | k6 load test + baseline comparison | Yes |
| 12 | E2E Tests | Playwright against staging URL | Yes |
| 13 | Mutation Tests | Stryker (nightly cron OR manual `RUN_MUTATION_TESTS`) | Yes |
| 14 | Deploy → Production | Manual gate → Kustomize apply → Argo Rollouts canary 25→50→100 | Yes |
| 15 | Release | On `v*.*.*` tag: re-tag + GitHub Release via `gh` | — |
| post-failure | Auto-rollback | `kubectl set image` to previous revision; push `change_failure_total` to Pushgateway | — |

---

## Directory layout

```
.
├── README.md                        ← this file
├── CHANGELOG.md                     ← every build's changes (newest first)
├── Jenkinsfile                      ← pipeline definition
├── package.json                     ← root: husky + lint-staged + commitlint + prettier
├── skaffold.yaml                    ← local hot-reload dev (Skaffold)
├── .env.example                     ← env vars template
├── .gitleaks.toml / .trivyignore    ← scanner allowlists
├── .husky/                          ← pre-commit + commit-msg hooks
├── .github/                         ← CODEOWNERS, PR/issue templates, dependabot, GH Actions
│
├── app/                             ← Express service (middleware, metrics, OTel, Postgres, Redis)
│   ├── src/                           middleware/, routes/, lib/{logger,metrics,otel,db,redis}/
│   ├── e2e/                           Playwright specs
│   ├── migrations/                    knex SQL migrations
│   ├── jest.config.js                 unit + integration projects
│   └── stryker.conf.json              mutation testing config
│
├── tests/                           ← out-of-app tests
│   ├── performance/                   k6 load test + baseline.json + compare-baseline.js
│   └── smoke/                         post-deploy axios checks
│
├── docker/                          ← Dockerfile, docker-compose, Jenkins JCasC, jenkins-agent image
├── k8s/                             ← Kustomize: base/ + overlays/{production,staging} + secrets/
├── argocd/                          ← GitOps Applications + bootstrap app-of-apps + ClusterIssuers
├── monitoring/                      ← Prometheus rules, Alertmanager config, Grafana dashboards, SLO defs, Velero schedules
├── policies/kyverno/                ← 9 admission policies + exception templates
├── chaos/                           ← Chaos Mesh experiments (staging-only blast radius)
├── scripts/                         ← setup.sh, release.sh, seal-secret.sh, pr-preview-{up,down}.sh, setup-branch-protection.sh
└── docs/                            ← runbook, dr-runbook, releasing, secrets, testing, etc.
```

---

## Where things live

| Looking for | Read |
|---|---|
| API contract | [`app/openapi.yaml`](./app/openapi.yaml) (also served at `GET /openapi.yaml`) |
| End-to-end demo walkthrough | [`docs/demo.md`](./docs/demo.md) |
| Production deployment checklist | [`docs/production-deployment.md`](./docs/production-deployment.md), `./scripts/production-checklist.sh` |
| Edge auth (Dex + oauth2-proxy) | [`docs/edge-auth.md`](./docs/edge-auth.md) |
| Dev container (VS Code) | [`.devcontainer/README.md`](./.devcontainer/README.md) |
| Custom Jenkins agent image | [`docs/agent-image.md`](./docs/agent-image.md) |
| Repo sanity check | [`scripts/check-repo.sh`](./scripts/check-repo.sh) (run via `make check`) |
| How the pipeline works | [`Jenkinsfile`](./Jenkinsfile), [`docs/runbook.md`](./docs/runbook.md) |
| How to deploy locally | [`docs/cluster-setup.md`](./docs/cluster-setup.md), [`docs/local-dev.md`](./docs/local-dev.md) |
| How to run tests | [`docs/testing.md`](./docs/testing.md) |
| Operational alerts + on-call | [`docs/runbook.md`](./docs/runbook.md), [`docs/oncall.md`](./docs/oncall.md), [`monitoring/prometheus.yaml`](./monitoring/prometheus.yaml) |
| Disaster recovery | [`docs/dr-runbook.md`](./docs/dr-runbook.md) |
| Postmortem template | [`docs/postmortem-template.md`](./docs/postmortem-template.md) |
| Secrets workflow | [`docs/secrets.md`](./docs/secrets.md) |
| Release flow | [`docs/RELEASING.md`](./docs/RELEASING.md) |
| PR previews | [`docs/pr-preview.md`](./docs/pr-preview.md) |
| Chaos engineering | [`docs/chaos-engineering.md`](./docs/chaos-engineering.md), [`chaos/README.md`](./chaos/README.md) |
| Database + migrations | [`docs/database.md`](./docs/database.md) |
| OpenTelemetry / tracing | [`app/src/lib/otel.js`](./app/src/lib/otel.js), [`docs/log-aggregation.md`](./docs/log-aggregation.md) |
| DORA metrics | [`docs/dora-metrics.md`](./docs/dora-metrics.md) |
| Cosign / signing trust | [`docs/cosign-trust.md`](./docs/cosign-trust.md) |
| Kyverno policy promotion | [`docs/policy-promotion.md`](./docs/policy-promotion.md) |
| Pre-commit hooks + dev loop | [`docs/dev-experience.md`](./docs/dev-experience.md) |
| Branch protection | [`docs/branch-protection.md`](./docs/branch-protection.md) |
| Why these tools | [`docs/tech-stack.md`](./docs/tech-stack.md) |

---

## Status

**All 6 production-readiness phases (A–F) plus 4 extended hardening tiers complete.** See [`CHANGELOG.md`](./CHANGELOG.md) for the build-by-build log.

| Tier | Builds | Closes |
|---|---|---|
| Phase A — bootstrap | 014 | Argo CD app-of-apps, sealed-secrets, kind nip.io |
| Phase B — agent image | 013 | Custom Jenkins agent with all CLIs bundled |
| Phase C — pipeline holes | 015 | Tempo, Promtail, DORA pushes, scanner enforcement, PR-teardown |
| Phase D — cluster security | 016 | Kyverno + 5 policies, NetworkPolicies, quotas, PSS-restricted, RBAC |
| Phase E — app data layer | 017 | Postgres, Redis, knex migrations, real health checks |
| Phase F — operations | 018 | Alertmanager receivers, Grafana dashboards, postmortem + on-call |
| Tier 1 — supply-chain | 019 | Multi-arch, grype, cosign keyless trust, SLSA provenance |
| Tier 2 — test depth | 020 | Playwright E2E, Stryker mutation, k6 baseline comparison |
| Tier 3 — policy enforce | 021 | Kyverno Audit→Enforce + 4 hardening policies |
| Tier 4 — resilience | 022 | Chaos Mesh, Velero + MinIO, DR runbook, synthetic monitoring |
| Tier 5 — DX | 023 | Pre-commit hooks, GH Actions PR checks, README rewrite |
| Tier 6 — Edge auth | 024 | Dex OIDC + oauth2-proxy + Ingress protection |
| Tier 7 — Polish + dev container | 025, 026 | LICENSE, Makefile, ServiceMonitor, repo sanity check, demo doc, VS Code dev container, pre-commit gitleaks |
| Tier 8 — Live-readiness | 027, 028 | Logger boot fix, production deployment guide + checklist, OpenAPI 3.0 spec served from `/openapi.yaml`, README badges |
| Tier 9 — README sync | 029 | Audit pass: API surface section, daily developer flow, navigation table additions, status table refresh |

### Going to cloud production

Five concrete substitutions. Walkthrough with commands in [`docs/production-deployment.md`](./docs/production-deployment.md). Run `./scripts/production-checklist.sh` to verify status — exits non-zero until all five are done.

1. **Real domain + Let's Encrypt prod issuer** — replace `*.127.0.0.1.nip.io` and `selfsigned-issuer` in both Ingress overlays.
2. **Custom registry + signed agent image** — build `docker/jenkins-agent/` to a real registry, update the reference in `docker/jenkins/jenkins.yaml`.
3. **Swap `REPLACE_ME` placeholders** — Alertmanager (Slack/PagerDuty/SMTP), Dex client secret, oauth2-proxy cookie/client secret. All via `scripts/seal-secret.sh`.
4. **Run `./scripts/setup-branch-protection.sh`** — codifies branch protection on `main` and `develop`.
5. **Promote `verify-image-signatures` Audit → Enforce** — only after ≥7 days of clean policyreports during soak.

Optional but recommended swaps (one-line config changes each):
- MinIO → native object storage (S3/GCS/Azure Blob) for Velero
- Tempo single-binary → `tempo-distributed` chart for HA
- kind → managed k8s (EKS/GKE/AKS/DO/Linode)
- Sealed Secrets → External Secrets + Vault if you need cross-cluster sharing

---

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md). Short version: feature branches off `develop`, Conventional Commits, one PR per logical change, all checks green.

## License

MIT — see [`LICENSE`](./LICENSE).
