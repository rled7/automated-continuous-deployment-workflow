# Automated Continuous Deployment Workflow

Production-grade Jenkins-based CI/CD pipeline for a Node.js Express app. **GitOps** with Argo CD, **progressive delivery** via Argo Rollouts, full **observability** (metrics + logs + traces), **supply-chain hardening** (SBOM + cosign + multi-arch), automated **cluster security** (Kyverno), **backups** (Velero), and **chaos engineering** (Chaos Mesh). Designed to run end-to-end on a local kind cluster — no cloud spend required.

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

### What would still need to change for cloud production

- Replace `app.127.0.0.1.nip.io` with a real domain.
- Swap `selfsigned-issuer` for `letsencrypt-prod` (cluster issuer already defined; just change the annotation).
- Replace MinIO with native object storage (S3 / GCS / Azure Blob).
- Swap Sealed Secrets for External Secrets + Vault if you need cross-cluster secret sharing.
- Replace `localhost:5000` registry with a real one (GHCR, ECR, GAR, Harbor).
- Promote `verify-image-signatures` Kyverno policy from Audit to Enforce after first signed deploy soaks for 7 days.
- Configure real Alertmanager receivers (replace `REPLACE_ME` placeholders in `argocd/bootstrap/apps/kube-prometheus-stack.yaml`).
- Run `./scripts/setup-branch-protection.sh` against the real GitHub repo.

---

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md). Short version: feature branches off `develop`, Conventional Commits, one PR per logical change, all checks green.

## License

This is a learning artifact. Add a `LICENSE` file if you publish.
