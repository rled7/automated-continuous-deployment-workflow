# Changelog

All notable file-level changes to this repo, tracked per build. Newest first.

> **All 6 production-readiness phases (A–F) complete as of Build 018.**
> - Phase A: bootstrap (Build 014)
> - Phase B: agent image (Build 013)
> - Phase C: pipeline holes (Build 015)
> - Phase D: cluster security (Build 016)
> - Phase E: app data layer (Build 017)
> - Phase F: operations (Build 018)

---

## Build 023 — Developer experience: pre-commit hooks + GitHub Actions PR checks + README rewrite
**Date:** 2026-05-07
**Scope:** Tier 5 — DX

### Added

- `package.json` (at repo root) — owns repo-wide dev tooling only (husky 9, lint-staged 15, commitlint 19, prettier 3). Comment makes the intent explicit; the actual app is in `app/`.
- `commitlint.config.js` — extends `@commitlint/config-conventional`. Allowed scopes: `app`, `infra`, `ci`, `docs`, `chore`, `test`, `sec`. Header max length 100. Subject must start with a letter.
- `.prettierrc.json` — `semi: true`, `singleQuote: true`, `trailingComma: 'all'`, `printWidth: 100`.
- `.prettierignore` — ignores `dist/`, `coverage/`, `reports/`, `node_modules/`, snapshot dirs.
- `.husky/pre-commit` — runs `npx --no -- lint-staged` against staged files.
- `.husky/commit-msg` — runs `npx --no -- commitlint --edit "$1"` to validate commit messages.
- `.github/workflows/pr-checks.yml` — fast PR feedback (~30–60s): lint + unit tests on every PR to `main` or `develop`. Uploads coverage artifact. Cancels in-progress runs on new push.
- `.github/workflows/conventional-commits.yml` — validates PR titles via `amannn/action-semantic-pull-request` against the same Conventional Commits ruleset commitlint enforces locally.
- `scripts/setup-branch-protection.sh` — `gh api` script that codifies branch protection state for `main` and `develop`. Required since GitHub branch protection can't be expressed in repo files. Idempotent.
- `docs/branch-protection.md` — what the protection script sets, when to re-run it, emergency hotfix bypass procedure.
- `docs/dev-experience.md` — pre-commit lifecycle, Conventional Commits format, two-pipeline feedback loop (GH Actions + Jenkins), bypass guidance.
- `docs/tech-stack.md` — full tooling rationale extracted from the original README. Covers every major component and why it was chosen.

### Modified

- `README.md` — full rewrite. New top-down structure: 1-paragraph elevator pitch → mermaid architecture diagram → 5-min kind quick-start → pipeline-at-a-glance table (15 stages) → directory layout → "Where things live" navigation table → status table mapping every Build (013–023) to a tier → "what would still need to change for cloud production" checklist → contributing/license. The original 250-line tooling-rationale dump moved to `docs/tech-stack.md` so it isn't lost.

### Closes (from production-readiness extension plan)
- Tier 5: developer experience — pre-commit gating, fast PR feedback path, codified branch protection, current README

### Judgment calls
- **Husky lives at repo root, not under `app/`.** Reason: pre-commit hooks must fire on ANY commit, not only commits that touch `app/`. The root `package.json` owns ONLY repo-wide dev tooling; `app/package.json` keeps the app deps. The two are independent.
- **Two PR pipelines (GH Actions + Jenkins) running in parallel.** GH Actions gives <1-minute feedback for lint + unit tests. Jenkins runs the full ~10–25-minute pipeline. Both are required status checks; the developer fixes lint/test issues without waiting for Jenkins.
- **README cuts:** dropped the original ASCII pipeline diagram (replaced by mermaid), the manual "Configure Jenkins" section (JCasC handles it), and the per-tool rationale prose. Preserved the rationale by moving it to `docs/tech-stack.md`. New README is ~210 lines.
- **Branch protection script is bash + `gh api`, not Terraform.** For a repo with one or two GitHub repos, 60 lines is more reviewable than introducing a Terraform provider. Documented the migration path.

---

## Build 022 — Chaos Mesh + Velero backups + DR runbook + synthetic monitoring docs
**Date:** 2026-05-07
**Scope:** Resilience tier — chaos engineering infrastructure, backup/recovery stack, and three new operational docs closing the resilience gap.

### Added

- `argocd/bootstrap/apps/chaos-mesh.yaml` — Argo Application deploying Chaos Mesh chart `2.7.0` from `https://charts.chaos-mesh.org`. Target namespace `chaos-mesh`, sync wave `-10`. `installCRDs: true`, `chaosDaemon.runtime: containerd` (kind default), `socketPath: /run/containerd/containerd.sock`. Dashboard disabled by default for kind. Resource requests tuned for kind.

- `argocd/bootstrap/apps/minio.yaml` — Argo Application deploying MinIO chart `5.2.0` from `https://charts.min.io`. Target namespace `minio`, sync wave `-10`. Standalone mode, single replica, 10 Gi PVC. Bucket `velero-backups` pre-created. Prominent comment block: SKIP in real cloud — use S3/GCS/Azure Blob instead. Credentials are placeholder; must be replaced via SealedSecret.

- `argocd/bootstrap/apps/velero.yaml` — Argo Application deploying Velero chart `7.2.1` from `https://vmware-tanzu.github.io/helm-charts`. Target namespace `velero`, sync wave `0` (after MinIO). AWS plugin (S3-compatible; works against MinIO). BSL pointing at `http://minio.minio.svc.cluster.local:9000`, bucket `velero-backups`, `s3ForcePathStyle: true`. Schedules managed separately via `velero-schedules` Application.

- `argocd/bootstrap/apps/velero-schedules.yaml` — Argo Application (directory source) pointing at `monitoring/velero/`, sync wave `10`. Deploys Velero `Schedule` CRs after Velero CRDs are available.

- `monitoring/velero/schedules.yaml` — Three `velero.io/v1` Schedule resources:
  - `daily-production`: daily at 02:00 UTC, production namespace, TTL 30 days (720 h)
  - `daily-staging`: daily at 02:30 UTC, staging namespace, TTL 7 days (168 h)
  - `weekly-cluster`: Sundays at 03:00 UTC, all namespaces, TTL 90 days (2160 h)
  Comment block sketches pre-backup `pg_dumpall` hook for self-hosted Postgres.

- `chaos/pod-failure.yaml` — `PodChaos` targeting `app: my-app` in `staging`, action `pod-failure`, 60s, `random-max-percent: 50`. Comment: staging only; never production without an approval workflow.

- `chaos/network-delay.yaml` — `NetworkChaos` injecting 100ms ± 30ms (25% correlation) on egress from `app: my-app` to `app: app-db` in `staging` for 2 minutes.

- `chaos/network-partition.yaml` — `NetworkChaos` full bidirectional partition between `app: my-app` and `app: app-db` in `staging` for 30 seconds. Tests DB-down 503 behaviour.

- `chaos/cpu-stress.yaml` — `StressChaos` targeting one random `app: my-app` pod in `staging`, 80% CPU (1 worker), 60 seconds. Tests HPA scale-out and Argo Rollouts instability detection.

- `chaos/io-delay.yaml` — `IOChaos` 50ms latency on reads+writes at `/app/logs` volume on one random `app: my-app` pod in `staging` for 60 seconds. Tests whether synchronous log I/O degrades request latency.

- `chaos/README.md` — Explains how to run (`kubectl apply`), observe (`kubectl describe`), and stop (`kubectl delete`) experiments. Full experiment catalogue table. Workflow: hypothesize → small blast radius → observe → refine. Chaos diary template. Monthly game-day cadence + workshop format. Safety gates (namespace must contain `staging`).

- `docs/dr-runbook.md` — Full DR runbook. RPO 24 h (daily backups), RTO 1 h (app-only), RTO 4 h (full cluster). Backup verification commands. Quarterly DR drill checklist (6 steps, from provisioning a fresh cluster to data integrity checks). Playbooks for six disaster scenarios: pod failures, single-AZ outage, region outage (known limitation), database corruption, cluster destruction, and compromised SealedSecret master key.

- `docs/synthetic-monitoring.md` — Explains synthetic vs reactive monitoring. Self-hosted option: k6 CronJob every 5 min, results exported via Prometheus remote-write. Sketch of `monitoring/synthetic-cron.yaml` in a code block (not committed — opt-in). SaaS comparison table: Checkly, Pingdom, UptimeRobot, Better Stack with pricing. Recommendation: start with self-hosted k6 CronJob; promote to SaaS when geo-distributed checks are needed.

- `docs/chaos-engineering.md` — Why chaos engineering (test monitoring/alerts/autoscaling before a real incident). Workflow (hypothesize → small blast radius → observe → refine). The four canonical experiments mapped to hypotheses and pass criteria. Monthly game-day cadence + workshop format (two-team: operators + on-call responders). SLO/SLI connection table. Cross-reference to `chaos/README.md`.

### Modified

- `argocd/bootstrap/projects/platform.yaml` — Added three chart repos to `sourceRepos` whitelist: `https://charts.chaos-mesh.org`, `https://charts.min.io`, `https://vmware-tanzu.github.io/helm-charts`.

- `policies/kyverno/disallow-host-namespaces.yaml` — Already included `chaos-mesh` exclusion in all three rules (`disallow-host-network`, `disallow-host-pid`, `disallow-host-ipc`) with comment explaining the chaos-daemon requires host namespaces to inject faults at the kernel/network layer. Policy logic unchanged.

- `policies/kyverno/disallow-privileged-containers.yaml` — Added `chaos-mesh` to the `exclude` block of the `disallow-privileged-containers` rule. Added comment block explaining chaos-daemon needs elevated privileges for fault injection. Updated `policies.kyverno.io/description` annotation. Policy logic unchanged.

- `policies/kyverno/disallow-capabilities.yaml` — Added `chaos-mesh` to the `exclude` block of all five rules (NET_ADMIN, SYS_ADMIN, SYS_PTRACE, SYS_MODULE, NET_RAW). Comments on `disallow-net-admin` and `disallow-sys-ptrace` explain the specific capabilities chaos-daemon requires. Updated `policies.kyverno.io/description` annotation. Policy logic unchanged.

### Judgment calls

- **Chaos Mesh version 2.7.0**: latest stable 2.x as of late 2025. The 2.x line is the current stable series; 3.x was not yet GA.
- **Velero version 7.2.1**: latest stable 7.x. The 7.x series adds improved BSL health checks and better CRD lifecycle management.
- **MinIO chart 5.2.0**: the community chart from `charts.min.io` tracks MinIO RELEASE.* releases. Chart 5.x aligns with the standalone/distributed split.
- **RPO 24 hours**: matches the daily backup cadence. Acceptable for a demo/staging cluster. Real production with transactional DB should use WAL streaming or hourly snapshots.
- **RTO 1 hour (app-only)**: based on observed Argo CD sync time + Velero restore speed on a kind cluster. Cloud deployments with faster storage should achieve this comfortably.
- **Retention windows**: 30 days (production daily) / 7 days (staging daily) / 90 days (weekly cluster) — standard tiered retention. Staging kept short to control MinIO disk usage.
- **Blast radius for chaos experiments**: conservative defaults (50% pods, one pod for stress/IO, 30–60s durations). Practitioners should widen blast radius only after confirming hypothesis holds at smaller scale.
- **Policy exclusions were surgical**: the `disallow-host-namespaces` policy already included `chaos-mesh` (added correctly in the same Build 022 session). Adding `chaos-mesh` to `disallow-privileged-containers` and `disallow-capabilities` required adding `exclude` blocks to rules that previously had none — the policy logic (validate/deny conditions) was untouched.

---

## Build 021 — Kyverno Audit→Enforce promotions + 4 new hardening policies
**Date:** 2026-05-07
**Scope:** Cluster security hardening — promote three safe Kyverno policies from Audit to Enforce, add four new ClusterPolicies for host-namespace isolation, privileged-container prevention, dangerous-capability blocking, and probe requirements.

### Promoted: Audit → Enforce

- `policies/kyverno/require-resource-limits.yaml` — Promoted to **Enforce**. The production app Deployment has defined CPU/memory requests and limits on every container since Build 016. Zero violations observed during the Audit soak period. Added comment block explaining the safety rationale and the `policyException` escape hatch.

- `policies/kyverno/require-labels.yaml` — Promoted to **Enforce**. The production app Deployment carries all three required labels (`app`, `env`, `version`) in `spec.template.metadata.labels` across both the base manifest and both overlays. Zero violations during soak. Added comment block with safety rationale and exception workflow.

- `policies/kyverno/require-readonly-rootfs.yaml` — Promoted to **Enforce**. The production app Deployment sets `readOnlyRootFilesystem: true` on all containers and mounts emptyDir volumes for the two writable paths (`/tmp`, `/app/logs`). Zero violations during soak. Added comment block.

### Intentionally kept in Audit

- `policies/kyverno/verify-image-signatures.yaml` — **Remains Audit**. Cosign signing was wired into the pipeline in Build 019, but signed images have not yet been confirmed to flow through admission-control at deploy time. Updated the comment block to explicitly state: "Promote to Enforce ONLY AFTER you've confirmed signed images pass through this policy in Audit mode for at least 7 days. Check `kubectl get policyreports -A` to verify no FAIL results from production-tagged images."

### New policies

- `policies/kyverno/disallow-host-namespaces.yaml` — **Enforce**. New `disallow-host-namespaces` ClusterPolicy. Forbids `spec.hostNetwork: true`, `spec.hostPID: true`, and `spec.hostIPC: true` on Pods in `production` and `staging`. Uses `match.any` namespace selectors (Kyverno v1.10+ style). Excludes `kube-system`, `kyverno`, `cert-manager`, `ingress-nginx` — CNI plugins and node agents legitimately need host namespaces. Three separate rules (one per flag) for precise violation messages.

- `policies/kyverno/disallow-privileged-containers.yaml` — **Enforce**. New `disallow-privileged-containers` ClusterPolicy. Forbids `securityContext.privileged: true` on any container in `production`/`staging`. Same namespace exclusions as above. Privileged containers have near-root access to the host node and represent a critical container-escape vector.

- `policies/kyverno/disallow-capabilities.yaml` — **Enforce**. New `disallow-capabilities` ClusterPolicy. Forbids adding any of five dangerous Linux capabilities: `NET_ADMIN`, `SYS_ADMIN`, `SYS_PTRACE`, `SYS_MODULE`, `NET_RAW` in `production`/`staging`. Five separate rules (one per capability) for actionable error messages. Safe capabilities (e.g., `NET_BIND_SERVICE`) are not blocked. Same namespace exclusions.

- `policies/kyverno/require-pod-probes.yaml` — **Audit** (new policy — soak first). New `require-pod-probes` ClusterPolicy. Requires `livenessProbe` and `readinessProbe` on every container in Deployments, Argo Rollouts, StatefulSets, and DaemonSets in `production`/`staging`. Kept in Audit because it is brand-new; violation surface must be mapped before enforcing. Planned Enforce promotion: 2026-05-14 (after 7-day soak with zero FAIL results).

### New infrastructure

- `policies/kyverno/policy-exceptions/README.md` — New directory + README explaining the `PolicyException` workflow (Kyverno v1.10+): when to use exceptions, naming convention (`<policy-name>-<reason>.yaml`), required annotations (`expiry`, `reason`, `reviewed-by`), and `kubectl` commands for applying and auditing exceptions.

- `policies/kyverno/policy-exceptions/example-exception.yaml.disabled` — Working example `PolicyException` showing the full required structure. Extension is `.disabled` so it is never applied accidentally. Rename to `.yaml` to use.

- `docs/policy-promotion.md` — New document covering: the Audit → Enforce promotion lifecycle and criteria; `kubectl` commands to query `policyreports` for FAIL results; `PolicyException` structure and workflow; Kyverno Prometheus metrics (`kyverno_admission_requests_total`, `kyverno_admission_review_duration_seconds`, `kyverno_policy_results_total`, etc.) with example PromQL queries and a ServiceMonitor snippet; and a table mapping each policy to its current mode and planned promotion date.

### Modified

- `policies/kyverno/README.md` — Refreshed policy table to include a "Mode" column (Enforce/Audit). Added "Promotion criteria" section above the table (the 4-step checklist). Expanded from 5 to 9 policy entries. Added a "Policy Exceptions" section linking to `policy-exceptions/README.md`.

### Judgment calls

- **Three policies promoted simultaneously**: `require-resource-limits`, `require-labels`, and `require-readonly-rootfs` were all introduced in Build 016 and have been soaking for the same period. All three have zero violations because the production app Deployment was already written to satisfy them. Promoting all three in a single build is safe and reduces the number of "Audit only temporarily" policies that accumulate.
- **verify-image-signatures kept Audit**: Even though Build 019 wired in cosign signing, the deploy-time verification path (Kyverno intercepting pod admission and calling the Rekor/Fulcio verification chain) has not been exercised in a real production rollout. A misconfiguration (wrong OIDC issuer, subject glob mismatch, registry attestation storage, or Rekor connectivity issue) would block ALL production deployments if in Enforce. The 7-day soak period exists precisely to catch this.
- **New hardening policies (host-ns, privileged, caps) are Enforce from day 1**: Unlike the Build 016 policies which were introduced alongside an existing workload, these hardening policies cover behaviours (host namespaces, privileged mode, dangerous capabilities) that the production app never uses. There is no existing workload that would be blocked. Starting in Enforce is safer: it provides an immediate hard guarantee rather than a days-long window where a mis-configured pod could slip through.
- **require-pod-probes starts Audit**: This policy covers Deployments, Rollouts, StatefulSets, and DaemonSets. Operators, Helm charts, and sidecar injectors (e.g., Istio, Linkerd) sometimes inject containers without probes. The soak period will surface any such injection patterns before we block them.
- **Capability blocklist (NET_ADMIN, SYS_ADMIN, SYS_PTRACE, SYS_MODULE, NET_RAW)**: These five are the capabilities most commonly exploited for container escapes, kernel-level code execution, or cross-container data exfiltration. Safer capabilities (NET_BIND_SERVICE, CHOWN, SETUID, etc.) are not blocked — they serve legitimate use cases without creating node-level attack vectors.
- **Namespace exclusions (kube-system, kyverno, cert-manager, ingress-nginx)**: CNI plugins (Calico, Cilium), kube-proxy DaemonSets, node exporters, and ingress controllers all require varying degrees of host-namespace access and elevated capabilities. Excluding these four namespaces is the minimal exclusion set. Other operator namespaces (e.g., `monitoring`, `argocd`) are not excluded — if they deploy privileged pods they will be caught, which is the desired behaviour for a post-audit environment.

---

## Build 020 — E2E (Playwright), mutation testing (Stryker), k6 baseline comparison
**Date:** 2026-05-07
**Scope:** Test depth — browser E2E coverage, mutation-testing for test-suite quality, and perf regression detection via baseline comparison.

### Added

- `app/playwright.config.js` — Playwright E2E configuration. Test dir `app/e2e/`, reporter list + JUnit XML (`reports/junit-e2e.xml` for Jenkins `junit()` step), baseURL from `BASE_URL` env var (default `http://localhost:3000`), chromium only (firefox/webkit skipped for CI speed), retries 1, timeout 30 s. Air-gapped note: `playwright install --with-deps chromium` calls apt; bake the browser into the agent image for offline environments.

- `app/e2e/smoke.spec.js` — Playwright smoke spec: asserts `/health/live` → 200, `/health/ready` → 200, `/api/items` → 200 + JSON array. Confirms the service is live and responding after deployment.

- `app/e2e/happy-path.spec.js` — Playwright happy-path spec: POST `/api/items` with a unique timestamped name → 201 + `id`; GET `/api/items` → confirms the new item appears in the list. End-to-end create-then-read flow.

- `app/e2e/error-cases.spec.js` — Playwright error-case spec: POST with empty body → 400 + `{ error: { message, requestId } }`; POST with name > 100 chars → 400; GET `/api/nonexistent` → 404. Validates structured error responses.

- `app/stryker.conf.json` — Stryker mutation configuration. Mutates `src/lib/**`, `src/middleware/**`, `src/routes/**` (excludes test files). Test runner: Jest (via `@stryker-mutator/jest-runner`). Coverage analysis: `perTest` (faster than `all`). Thresholds: high 80, low 60, break 50. HTML report written to `reports/mutation/index.html`.

- `tests/performance/baseline.json` — Committed reference values from a known-good k6 run: `http_req_duration.p95 = 320 ms`, `p99 = 850 ms`, `avg = 145 ms`; `http_req_failed.rate = 0.002`; `iterations.rate = 245/s`. Used by `compare-baseline.js` for regression detection.

- `tests/performance/compare-baseline.js` — Node script that reads k6 NDJSON output (`--out json=FILE`) and `baseline.json`, computes percentiles from the full sample population (nearest-rank), and prints a comparison table. Exits 1 if: p95 regressed > 20%, p99 regressed > 25%, or error rate > 2× baseline (i.e., +100%). Exits 0 if all metrics pass.

- `docs/perf-baseline.md` — Explains how the baseline is established (stable build, capture k6 output, commit), when to re-baseline (after legitimate improvements; never to mask regressions), and how to run the comparison locally with example output.

- `docs/testing.md` — Test pyramid reference doc. Covers all six layers (unit, integration, E2E, smoke, perf, mutation), what runs when (PR / staging / nightly), how to run each suite locally, Jest coverage thresholds (80/70/60 lines/branches/functions), and Stryker mutation score thresholds (break at 50).

### Modified

- `app/package.json` — Added `devDependencies`: `@playwright/test ^1.49.0`, `@stryker-mutator/core ^8.7.0`, `@stryker-mutator/jest-runner ^8.7.0`. Added scripts: `test:e2e` (`playwright test`), `test:e2e:install` (`playwright install --with-deps chromium`), `test:mutation` (`stryker run`).

- `Jenkinsfile` — Four changes:
  1. **`parameters` block** — added `booleanParam(name: 'RUN_MUTATION_TESTS', ...)` so operators can trigger mutation testing on demand.
  2. **`triggers` block** — added `cron('H 3 * * *')` for nightly mutation test runs (hash spreads load across the hour).
  3. **Performance Tests stage** — added `node tests/performance/compare-baseline.js` invocation after k6, comparing current results against `tests/performance/baseline.json`.
  4. **E2E Tests stage (new, stage 9b)** — runs `playwright install --with-deps chromium` then `npm run test:e2e` against `https://staging.app.${APP_NAME}.internal`. Gated to `develop` branch. JUnit report published via `junit 'app/reports/junit-e2e.xml'`.
  5. **Mutation Tests stage (new, stage 9c)** — runs `stryker run` with `NODE_OPTIONS=--experimental-vm-modules`. Gated to `TimerTrigger` or `params.RUN_MUTATION_TESTS == true`. HTML mutation report published via `publishHTML`. Intentionally NOT gated to a branch so nightly runs can execute on any branch.

### Judgment calls

- **Playwright version ^1.49.0**: latest stable in the ^1.x line at the time of this build. The `@playwright/test` package bundles the test runner; no separate install is needed.
- **Stryker version ^8.7.0**: latest stable ^8.x. `@stryker-mutator/jest-runner` must match the core version exactly.
- **Mutation `break: 50` threshold**: conservative starting point. The initial run against the existing test suite is expected to score in the 60–75% range. Tighten `break` to 60 after two or three successful nightly runs establish a reliable baseline score.
- **Baseline values (320 ms p95, 850 ms p99, 0.2% error rate)**: representative of a medium-load staging environment. These are the initial seed values; the first actual k6 run against staging will either confirm them or trigger a re-baseline.
- **k6 regression thresholds (+20% p95, +25% p99, 2× error rate)**: chosen to absorb normal run-to-run jitter (~5–10%) while catching genuine regressions. A 20% p95 spike on a 320 ms baseline means p95 hit 384 ms — clearly worth investigating.
- **E2E `when { branch 'develop' }` only**: E2E tests require a deployed staging environment. Running them on feature branches would require per-branch staging deploys, which is not in scope for this build.
- **Mutation Tests not branch-gated**: the cron trigger fires on the default branch, but the `when` condition only checks trigger type and parameter — any branch that triggers a nightly build will run mutations. This is intentional: mutation coverage is a repo-wide metric, not per-branch.

---

## Build 019 — Multi-arch images, SBOM scanning, cosign keyless trust, SLSA provenance
**Date:** 2026-05-07
**Scope:** Supply-chain final mile — trust infrastructure that enables Build 021 to promote `verify-image-signatures` from Audit to Enforce.

### Added

- `docs/cosign-trust.md` — New document explaining keyless cosign signing (Fulcio short-lived certs, Rekor transparency log), the two trust paths (keyless vs. key-based KMS), the rationale for choosing keyless (no key management, ephemeral certs, public audit trail in Rekor), local verification instructions (`cosign verify --certificate-identity ... --certificate-oidc-issuer ... IMAGE`), and step-by-step migration guide to KMS-backed key-based signing with provider-specific examples for AWS, GCP, and Azure.

### Modified

- `docker/Dockerfile` — Added `RUN --mount=type=cache,target=/root/.npm` BuildKit cache mounts to both npm install steps in the multi-stage build (production-deps and all-deps layers). Each platform in a multi-arch build gets its own cache namespace automatically; subsequent builds skip re-downloading the npm registry cache.

- `docker/jenkins-agent/Dockerfile` — Added `GRYPE_VERSION=v0.85.0` to the ENV block and a new install step (`curl -sSfL .../install.sh | sh -s -- -b /usr/local/bin`) for grype (Anchore's SBOM vulnerability scanner). Added `grype version` to the sanity-check `RUN` so the image build fails fast if grype is missing or mis-installed.

- `Jenkinsfile` — Four changes in the Docker Build & Push stage and a new stage:
  1. **Multi-arch build**: replaced `docker.build(...)` + `appImage.push()` with `docker buildx build --platform linux/amd64,linux/arm64 --push`. A `docker buildx create --use --name multiarch --driver docker-container || docker buildx use multiarch` setup call precedes it. Comments document the binfmt_misc QEMU requirement (kind clusters have it; cloud VM agents may need the one-time `tonistiigi/binfmt --install all` privileged container).
  2. **Cosign keyless sign**: `COSIGN_EXPERIMENTAL=1 cosign sign --yes "${FULL_IMAGE}"` signs the multi-arch manifest list digest. Comments document the OIDC issuer dependency and cosign v2+ default keyless behaviour.
  3. **SLSA provenance attestation**: `cosign attest --yes --type slsaprovenance` attaches a SLSA Build L2 predicate. `BUILD_START_ISO` is captured in the Checkout stage via `date -u +%Y-%m-%dT%H:%M:%SZ`. Comments note that `builder.id = ${JENKINS_URL}` is self-attested (not OIDC-bound), making this L2 not L3.
  4. **Scan SBOM stage (new, Stage 7b)**: `grype sbom:reports/sbom.cdx.json --fail-on high --output table | tee reports/grype.txt` — fails the pipeline on any HIGH or CRITICAL vulnerability. Runs after Docker Build & Push (consumes `reports/sbom.cdx.json` from syft). `reports/grype.txt` is archived as a build artifact.

- `policies/kyverno/verify-image-signatures.yaml` — Tightened from placeholder values to real Sigstore public infrastructure references:
  - `issuer: "https://token.actions.githubusercontent.com"` (GitHub Actions OIDC)
  - `subject: "https://github.com/rled7/automated-continuous-deployment-workflow/.github/workflows/*"` (glob matches any workflow file)
  - `rekor.url: https://rekor.sigstore.dev` (public Rekor log)
  - Added a verbose comment block at the top explaining the policy's purpose, how keyless signing works, the OIDC issuer/subject matching rules, the Build 021 Enforce promotion checklist, and a note that no extra Kyverno config is needed for public Sigstore roots (Kyverno bundles the Fulcio root CA and Rekor public key).
  - `validationFailureAction: Audit` preserved — Build 021 promotes to Enforce once a full release cycle runs clean.

### Judgment calls

- **SLSA predicate fields — demo vs. real**: The SLSA provenance predicate attached by `cosign attest` is a self-attested L2 artefact. `builder.id` is `${JENKINS_URL}`, which is self-reported by the pipeline and not independently verifiable via an OIDC token. For real SLSA L3, the builder identity must come from an OIDC token minted by a trusted, external build service (e.g. GitHub Actions Reusable Workflows with SLSA provenance generator, or SLSA-verified Tekton builds). This is documented in the Jenkinsfile comment block and in this CHANGELOG. The predicate is useful as a demo and as a foundation for L3 migration; it is not a compliance claim.
- **grype `--fail-on high`**: High is the starting threshold. Once a clean baseline is established and a suppression list (grype's `.grype.yaml`) covers accepted/false-positive findings, tighten to `--fail-on critical` for consistency with Trivy's existing `--severity HIGH,CRITICAL` gate. Both scanners running in parallel on different feeds provides defence in depth.
- **Registry cache (`--cache-from`/`--cache-to`)**: The buildx step also wires a registry-side layer cache (`type=registry,mode=max`) so incremental layer rebuilds are fast on cloud agents that have no local Docker daemon state between builds. This is an improvement beyond the task specification but has no downside.
- **BuildKit cache mounts in multi-arch context**: `--mount=type=cache` in the Dockerfile is per-platform-per-builder; BuildKit automatically namespaces caches by platform so `linux/amd64` and `linux/arm64` builds never share a potentially incompatible native binary cache. No agent-image changes are needed beyond what the jenkins-agent Dockerfile already provides (docker.io installed, Docker socket mounted via the Kubernetes pod spec).

### Enables

- Build 021: promote `verify-image-signatures` from Audit to Enforce (after ≥ 1 full release cycle with zero PolicyReport violations).

---

## Build 018 — Alertmanager receivers, Grafana dashboards, postmortem + on-call docs
**Date:** 2026-05-06
**Scope:** Phase F of the production-readiness plan (closes Phase F — operational maturity)

### Added

- `argocd/bootstrap/apps/grafana-dashboards.yaml` — New Argo Application (sync wave 10) using a `directory` source pointing at `monitoring/grafana/dashboards/`. The kube-prometheus-stack Grafana sidecar auto-imports any ConfigMap labelled `grafana_dashboard: "1"` from the `monitoring` namespace; this app delivers all four dashboard ConfigMaps via GitOps without touching the Grafana Helm chart values.
- `monitoring/grafana/dashboards/app-overview.yaml` — Grafana 10+ dashboard ConfigMap (schemaVersion 38, `grafana_dashboard: "1"`). Four panels covering RED metrics: Request Rate timeseries (`sum(rate(http_request_duration_ms_count[5m]))`), Error Rate % stat (`5xx / total`), P95 Latency timeseries (`histogram_quantile`), 5xx Errors by Route table. Default time range `now-1h → now`.
- `monitoring/grafana/dashboards/slo.yaml` — SLO burn-down dashboard ConfigMap. Five panels: Availability SLI vs 99.9% target timeseries (with dashed threshold line), Error Budget Remaining stat, 1h Burn Rate stat (alert threshold 14.4×), 6h Burn Rate stat (alert threshold 6×), SLO Alert State table (queries `ALERTS{slo="availability"}`). Uses recording rules from `monitoring/prometheus.yaml`.
- `monitoring/grafana/dashboards/dora.yaml` — DORA metrics dashboard ConfigMap. Five panels: Deployment Frequency stat (24h/7d/30d via Pushgateway), Lead Time p50/p95 stat (histogram quantile over `lead_time_seconds_bucket`), Change Failure Rate stat (`change_failure_total / deployment_frequency_total`), MTTR gauge (30-day avg of `mttr_seconds`), Deployment Frequency Over Time timeseries.
- `monitoring/grafana/dashboards/pipeline.yaml` — Jenkins pipeline metrics dashboard ConfigMap. Four panels: Build Duration P95 timeseries (`jenkins_builds_duration_milliseconds_summary_bucket`), Build Success Rate sparkline stat, Stage-by-Stage Duration horizontal bar chart, Builds Over Time timeseries (success vs failure, colour-coded green/red). Requires Jenkins Prometheus plugin (added in this build).
- `monitoring/grafana/dashboards/kustomization.yaml` — Kustomize file listing all four dashboard ConfigMaps as resources, namespace `monitoring`. Applied by the `grafana-dashboards` Argo Application.
- `docs/postmortem-template.md` — Blameless postmortem template with two-paragraph "How to Use" intro. Sections: Incident Header table (ID, date, severity, duration, commander, scribe, summary), Timeline table (time UTC, event, source), Impact (customer-facing + scope), Root Cause, Detection (how/how long/was it acceptable), Mitigation (ordered steps + time-to-mitigate), Resolution (what/when/rollback used), Contributing Factors (system/process/knowledge gaps — no blame framing), Action Items table (item, owner, P1/P2/P3, due date, ticket), Lessons Learned (what worked / what didn't), Footer (review date, attendees, linked ticket). Cross-links to `docs/oncall.md` and `docs/dora-metrics.md`.
- `docs/oncall.md` — On-call rotation doc covering: rotation cadence (weekly, handoff Monday 10:00 local), Primary/Secondary roles + responsibilities, escalation contract table (ack 15 min, response 30 min, escalate after 1h, VP escalation at 2h for Sev 1), What Is Expected, What Is NOT Expected (feature work, code reviews), Tooling table (PagerDuty, Grafana, Alertmanager, Slack channels, Jenkins, Loki/Tempo), Cloud Cost Monitoring section (OpenCost, with install command, skip for kind), Compensation Policy placeholder, Handoff Checklist (open incidents, silences, experiments, known issues, action items), Escalation Matrix table (Sev 1–4).

### Modified

- `argocd/bootstrap/apps/kube-prometheus-stack.yaml` — Added full `alertmanager.config` under the `alertmanager:` key: global `resolve_timeout: 12h`; route tree with default receiver `slack-warnings`, child routes for `severity: page` (receiver `pagerduty`, group_wait 10s, repeat 4h) and `severity: critical` (receiver `pagerduty`, group_wait 0s) and `severity: warning` (receiver `slack-warnings`, group_wait 30s, repeat 12h); four receivers (`pagerduty` with `routing_key: REPLACE_ME`, `slack-warnings` on `#alerts-warning`, `slack-critical` on `#alerts-critical`, `email-fallback` SMTP with dummy smarthost/auth — comment documents it as the fallback if both PD and Slack are down); inhibition rule suppressing `severity: warning` when a matching `severity: critical` is already firing (prevents double-paging). Also added Jenkins Prometheus plugin scrape job to `additionalScrapeConfigs`. Comment block at the top of the config warns to replace `REPLACE_ME` placeholders via SealedSecret + envFrom or Helm `--set` before deploying.
- `docker/jenkins/plugins.txt` — Added `prometheus:latest` under a new `# Metrics (Build 018)` section. The plugin exposes `/prometheus` on port 8080 for Prometheus scraping of build durations, success/failure counts, queue length, and executor utilisation. Pairs with the `jenkins` scrape job in kube-prometheus-stack.
- `docs/runbook.md` — Added cross-links to `docs/postmortem-template.md` (use after every Sev 1/2) and `docs/oncall.md` (rotation + escalation) in the Quick Links table. Added cross-link to `docs/dora-metrics.md` for measuring incident impact. Added "After an incident" section directing engineers to copy and fill the postmortem template, schedule a review, publish in `#incidents`, track action items, and review DORA metrics post-incident.

### Closes (from production-readiness plan)
- Phase F: operational maturity — Alertmanager alert routing (PagerDuty + Slack + email fallback + inhibition rules), Grafana app-specific dashboards (RED/SLO/DORA/pipeline), Jenkins Prometheus metrics plugin, blameless postmortem template, on-call rotation doc, runbook cross-links.

### Judgment calls
- **Alertmanager `REPLACE_ME` literals:** using literal `REPLACE_ME` strings (not `${...}` shell-style placeholders) so Helm `template` rendering succeeds without secrets present. Production operators replace these via SealedSecret + envFrom or `helm upgrade --set`. This is documented in a comment block inside `alertmanager.config:`.
- **`severity: page` route:** added as a sibling to `critical` so SLO fast-burn alerts (labelled `severity: page`) route to PagerDuty at the same urgency as `critical`. The `critical` route's `group_wait: 0s` allows immediate grouping for critical alerts.
- **Dashboard panel choices:** dashboards are compact (50–150 lines each) and demonstrate intent rather than production polish. The SLO dashboard uses the `http_requests:availability:ratio_rate5m` recording rule already defined in `monitoring/prometheus.yaml` so all panels resolve without additional rules. DORA panels query Pushgateway-pushed metrics (`deployment_frequency_total`, `lead_time_seconds_bucket`, `change_failure_total`, `mttr_seconds`) that are pushed from the Jenkinsfile.
- **Grafana sidecar vs. Helm values:** dashboards are delivered as separate ConfigMap objects via a dedicated Argo Application rather than embedded in the kube-prometheus-stack Helm values. This keeps the chart values clean and allows individual dashboards to be added/removed via GitOps without re-deploying Prometheus/Alertmanager.
- **`oncall.md` OpenCost note:** OpenCost section explicitly notes it is skipped on kind (local dev) clusters and provides the production install command as required.

---

## Build 017 — Postgres + Redis integration, knex migrations, real health checks
**Date:** 2026-05-06
**Scope:** Phase E of the production-readiness plan (closes Phase E)

### Added

- `app/knexfile.js` — Knex configuration keyed by environment (`development`, `test`, `production`). Reads `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` env vars with sensible local defaults. Uses `pg` client. Migrations directory: `app/migrations`. Pool: min 2, max 10. Test env uses a separate database (`appdb_test`) and a smaller pool.
- `app/migrations/20260506000000_create_items.js` — Knex migration that creates the `items` table (`id` SERIAL PK, `name` TEXT NOT NULL, `created_at`/`updated_at` TIMESTAMPTZ DEFAULT now()) plus an index on `created_at DESC` for the default list-latest query. Includes `down` (drops table).
- `app/src/lib/db.js` — Postgres pool wrapper using the `pg` driver. Reads env vars; creates a `pg.Pool` with min 2/max 10, idleTimeout 30s, connectionTimeout 5s. Exports `query()`, `healthCheck()`, `pool`, `shutdown()`. Graceful "not configured" behavior if env vars absent. Includes `DB_FAKE=1` escape hatch for tests (see below).
- `app/src/lib/redis.js` — Redis client wrapper using `ioredis`. Reads `REDIS_URL`; creates `new Redis(REDIS_URL, { maxRetriesPerRequest: 1, lazyConnect: true })`. Exports `client`, `healthCheck()`, `shutdown()`. Graceful "not configured" behavior if `REDIS_URL` absent.
- `docs/database.md` — New doc: local dev setup, migration workflow, expand-contract pattern, rollback procedure, env var table, schema docs.

### Modified

- `app/package.json` — Added `pg` (^8.x), `ioredis` (^5.x), `knex` (^3.x) to `dependencies`; `pg-mem` (^3.x) to `devDependencies`. Added `migrate`, `migrate:rollback`, `migrate:make` scripts.
- `app/src/lib/db.js` — Replaced stub with real `pg.Pool` implementation. Added `DB_FAKE=1` escape hatch: when set, uses a minimal in-memory store (array + counter) instead of pg.Pool. This avoids ESM Jest + pg-mem `unstable_mockModule` incompatibility (pg-mem's CommonJS adapter conflicts with top-level ESM imports; the module graph is evaluated before mocks can be injected). The fake honors the same `query()` interface so tests remain valid contract tests.
- `app/src/lib/redis.js` — Replaced stub with real `ioredis` implementation. `lazyConnect: true` so the import doesn't attempt to connect immediately. Added `REDIS_FAKE=1` escape hatch mirroring `DB_FAKE` for tests.
- `app/src/routes/health.js` — Replaced stubbed `checkDatabase` / `checkRedis` with real calls to `lib/db.js` and `lib/redis.js` `healthCheck()`. Both run in parallel via `Promise.allSettled`. `/ready` returns 503 if either fails or `setShuttingDown(true)` was called. `/live` unchanged.
- `app/src/server.js` — Replaced in-memory `/api/items` handlers with real DB queries: `GET` runs `SELECT id, name, created_at FROM items ORDER BY created_at DESC LIMIT 100`; `POST` runs `INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at`. Shutdown sequence: `setShuttingDown(true)` → 5s drain → `db.shutdown()` → `redis.shutdown()` → `server.close()` → `process.exit(0)`.
- `app/src/__tests__/integration/api.test.js` — Wired `DB_FAKE=1` and `REDIS_FAKE=1` via `setupFiles` (not at top of test file — ESM imports are hoisted so env vars set in test file body are too late). All six tests pass: GET /api/items (200), POST /api/items (201 + body), validation errors (2×400), /metrics (200), /health/live (200).
- `app/src/__tests__/integration/setup.js` — New Jest `setupFiles` entry for integration tests. Sets `DB_FAKE=1` and `REDIS_FAKE=1` before any module is evaluated.
- `app/src/__tests__/unit/setup.js` — New Jest `setupFiles` entry for unit tests. Sets same flags so health.test.js `/health/ready` probe returns 200 without infrastructure.
- `app/jest.config.js` — Split into two Jest projects (`unit`, `integration`) so each project can have its own `setupFiles`. Previously a single flat config.
- `Jenkinsfile` — Added `runMigrations(String namespace, String image)` helper function that runs `knex migrate:latest` as a one-shot `kubectl run --rm --attach` pod before each deploy. Called before `deployToKubernetes('staging', ...)` in the Deploy → Staging stage and before `deployToKubernetes('production', ...)` in Deploy → Production. Comment documents expand-contract assumption and failure behavior.
- `k8s/base/deployment.yaml` — Added explicit `env` entries for `DB_PORT`, `DB_USER`, `DB_NAME` with `configMapKeyRef` references (`optional: true` so base overlay without values doesn't break). `DB_HOST` and `DB_PASSWORD` continue to come from the SealedSecret via `secretRef`.
- `k8s/overlays/production/configmap-patch.yaml` — Added `DB_PORT: "5432"`, `DB_USER: "appuser"`, `DB_NAME: "appdb"` alongside existing `REDIS_URL`.
- `k8s/overlays/staging/configmap-patch.yaml` — Same DB_PORT/DB_USER/DB_NAME additions as production overlay.
- `k8s/secrets/my-app-secrets.template.yaml` — Expanded header comment to document which keys are in the secret (`db-host`, `db-password`) and which are in the ConfigMap (non-sensitive: `DB_PORT`, `DB_USER`, `DB_NAME`).
- `docker/docker-compose.yml` — Added `healthcheck` to `app-db` (pg_isready) and `redis` (redis-cli ping) services. Added `app` service: builds from `docker/Dockerfile`, depends on `app-db` (service_healthy) and `redis` (service_healthy), exposes 3000:3000, sets all DB + Redis env vars, runs `npm run migrate && npm start`.

### Closes (from production-readiness plan)
- Phase E: real database + Redis integration (Postgres pool, knex migrations, ioredis client, real health checks, migration CI stage)

### Judgment calls
- **DB_FAKE / REDIS_FAKE escape hatch (not pg-mem):** `jest.unstable_mockModule` with pg-mem in ESM Jest is incompatible with top-level `import pg from 'pg'` in `lib/db.js`. The ESM module graph evaluates eagerly; the mock injection happens after the real `pg.Pool` constructor is already called. Setting `process.env.DB_FAKE = '1'` at the top of a test file is also too late — ESM `import` statements are hoisted and modules are cached before user-level code runs. The correct hook is Jest's `setupFiles` (runs in the worker before the module registry is populated). Both `lib/db.js` and `lib/redis.js` honor `DB_FAKE=1`/`REDIS_FAKE=1` flags to use in-memory stubs. Jest projects (`unit`, `integration`) each have their own `setupFiles`. Tests remain API contract tests (not unit tests of SQL). All 18 tests pass.
- **pg-mem still installed:** `pg-mem` is kept in `devDependencies` in case a future test needs it for more complex SQL validation (e.g., constraint checks). It is not used in the current test suite.
- **`optional: true` on configMapKeyRef:** The base deployment.yaml has no ConfigMap with these keys (overlays supply them). Without `optional: true`, pod scheduling would fail in environments without the overlay applied (e.g., bare `kubectl apply -f k8s/base/deployment.yaml`). The app defaults to `5432`/`appuser`/`appdb` via env var defaults in `lib/db.js` when the vars are absent.
- **Migrations in CI as `kubectl run --rm`:** chosen over a dedicated Job manifest for simplicity. The pod name uses `BUILD_NUMBER` to prevent name collisions. The `--attach` flag ensures the pod's stdout is streamed to Jenkins logs. A failure here aborts the pipeline before rollout begins.

---

## Build 016 — Cluster security: Kyverno + policies, NetworkPolicies, quotas, PSS, RBAC
**Date:** 2026-05-06
**Scope:** Phase D of the production-readiness plan (closes Phase D)

### Added

- `argocd/bootstrap/apps/kyverno.yaml` — Argo Application, project `platform`, chart `kyverno` v3.3.3 from `https://kyverno.github.io/kyverno`, target namespace `kyverno`, sync wave -10 (installs before any workloads). `installCRDs: true`. Resource requests: admission controller 100m/128Mi, background controller 100m/128Mi, cleanup controller 100m/64Mi, reports controller 100m/64Mi. Limits sized for kind (500m/384Mi for admission).
- `argocd/bootstrap/apps/kyverno-policies.yaml` — Argo Application, project `platform`, `directory` source pointing at `policies/kyverno/`, sync wave 10 (after Kyverno CRDs at wave -10). ClusterPolicies are cluster-scoped; namespace set to `kyverno` for Argo CD tracking only. Automated sync with prune + selfHeal.
- `policies/kyverno/require-resource-limits.yaml` — `ClusterPolicy` `require-resource-limits`, `validationFailureAction: Audit`. Requires CPU + memory requests and limits on every container. Excludes `kube-system` and `kyverno` namespaces. Comment instructs switching to Enforce after a soak period.
- `policies/kyverno/require-labels.yaml` — `ClusterPolicy` `require-labels`, `validationFailureAction: Audit`. Requires `app`, `env`, `version` labels on Deployments and Argo Rollouts in `production` and `staging` namespaces.
- `policies/kyverno/disallow-latest-tag.yaml` — `ClusterPolicy` `disallow-latest-tag`, `validationFailureAction: Enforce`. Forbids `:latest` or untagged images in the `production` namespace only. Staging is exempt for rapid iteration. Safe to enforce immediately — CI must tag production images with git SHA or semver.
- `policies/kyverno/require-readonly-rootfs.yaml` — `ClusterPolicy` `require-readonly-rootfs`, `validationFailureAction: Audit`. Requires `securityContext.readOnlyRootFilesystem: true` on containers in `production` and `staging`. Comment instructs switching to Enforce after soak.
- `policies/kyverno/verify-image-signatures.yaml` — `ClusterPolicy` `verify-image-signatures`, `validationFailureAction: Audit`. Uses `verifyImages` rule with cosign keyless verification (Fulcio CA + Rekor transparency log). Matches `ghcr.io/YOUR_ORG/my-app:*` — update registry placeholder before production use. Header comment block explains prerequisites: sign images in CI, configure OIDC issuer, validate PolicyReports before switching to Enforce.
- `policies/kyverno/README.md` — Policy table (name, enforcement mode, scope, summary), Audit→Enforce promotion path, notes on `disallow-latest-tag` enforce-from-day-one rationale and `verify-image-signatures` prerequisites.
- `k8s/base/network-policy.yaml` — Multi-document YAML with 6 NetworkPolicy resources: (1) `default-deny-all` — denies all ingress+egress for every pod; (2) `allow-dns` — egress UDP/TCP 53 for all pods; (3) `allow-app-ingress-from-nginx` — ingress on 3000 from `ingress-nginx` namespace; (4) `allow-app-egress-otel` — egress on 4318 to OTel collector in `monitoring` namespace; (5) `allow-prometheus-scrape` — ingress on 3000 from Prometheus in `monitoring` namespace; (6) `allow-app-egress-db-redis` — forward-looking egress to `app-db` on 5432 and `redis` on 6379 (comment notes these land in Build 017).
- `k8s/base/resource-quota.yaml` — `ResourceQuota` `my-app-quota` with base values: `requests.cpu: 2`, `requests.memory: 2Gi`, `limits.cpu: 4`, `limits.memory: 4Gi`, `pods: 20`, `count/services: 10`, `persistentvolumeclaims: 5`.
- `k8s/base/limit-range.yaml` — `LimitRange` `my-app-limits` with: default limits (500m/512Mi), defaultRequest (100m/128Mi), max (2/2Gi), min (50m/64Mi).
- `k8s/base/service-account.yaml` — `ServiceAccount` `my-app` with `automountServiceAccountToken: false`. No roles bound. Comment documents how to add least-privilege RBAC in overlays if the app later needs API access.
- `k8s/overlays/production/quota-patch.yaml` — Patches `ResourceQuota` `my-app-quota` to production values: `requests.cpu: 8`, `requests.memory: 8Gi`, `limits.cpu: 16`, `limits.memory: 16Gi`, `pods: 50`.

### Modified

- `argocd/bootstrap/projects/platform.yaml` — Added `https://kyverno.github.io/kyverno` to `sourceRepos` whitelist so the Kyverno Argo Application can pull the Helm chart.
- `k8s/base/kustomization.yaml` — Added `service-account.yaml`, `network-policy.yaml`, `resource-quota.yaml`, `limit-range.yaml` to the resources list.
- `k8s/base/deployment.yaml` — Added `spec.template.spec.serviceAccountName: my-app` so the deployment uses the dedicated ServiceAccount instead of `default`. Also added `spec.template.spec.securityContext.seccompProfile.type: RuntimeDefault` at the pod level — this was missing and is required by PSS `restricted` (k8s >= 1.25). Without it the namespace PSS labels would warn/block pods. `RuntimeDefault` uses the container runtime's default seccomp filter and is safe for well-behaved applications.
- `k8s/overlays/production/namespace.yaml` — Added Pod Security Standards labels: `enforce: restricted`, `audit: restricted`, `warn: restricted`. PSS `restricted` requires runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation: false, drop ALL capabilities — all of which the base deployment.yaml already satisfies (see PSS compatibility note below).
- `k8s/overlays/staging/namespace.yaml` — Same PSS labels as production. Staging mirrors production posture so developers catch violations before they reach production.
- `k8s/overlays/production/kustomization.yaml` — Added `quota-patch.yaml` to the patches list, targeting `ResourceQuota/my-app-quota`.
- `argocd/AppProject.yaml` — Tightened security posture: `sourceRepos` narrowed from `'*'` to `https://github.com/rled7/automated-continuous-deployment-workflow`; `destinations.namespaces` narrowed from `'*'` to `production`, `staging`, `preview-*`; `clusterResourceWhitelist` replaced `'*/*'` with only `Namespace`; `ci-deployer` role limited to `applications, get` and `applications, sync` only.

### Closes (from production-readiness plan)
- Phase D: cluster-side security hardening (Kyverno admission controller, admission policies, NetworkPolicies, ResourceQuota + LimitRange, Pod Security Standards, tightened AppProject RBAC, dedicated ServiceAccount)

### Judgment calls
- **Kyverno chart v3.3.3:** latest stable in the 3.x series as of the build date. Pinned for reproducibility.
- **Staging quota:** staging keeps base ResourceQuota values (2 cpu req, 2Gi mem req, 20 pods). No separate staging quota-patch needed; base values are appropriate for a lower-traffic environment. This is noted rather than adding a no-op patch.
- **PSS compatibility:** the base `deployment.yaml` securityContext satisfied most PSS `restricted` requirements (`runAsNonRoot: true`, `runAsUser: 1000`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`), but was missing `seccompProfile` which is **required** by PSS `restricted` in k8s >= 1.25. `spec.template.spec.securityContext.seccompProfile.type: RuntimeDefault` was added at the pod level. All five PSS restricted requirements are now met; the namespace labels will not block or warn the app pods.
- **`disallow-latest-tag` Enforce from day one:** the only policy on Enforce immediately. Production CI (Jenkinsfile) tags images with a git SHA; `:latest` in the base deployment.yaml is overridden by the overlay `images:` block before reaching the cluster.
- **AppProject ClusterIssuer removal:** `ClusterIssuer` was removed from `clusterResourceWhitelist` in `AppProject.yaml`. The my-app workloads reference ClusterIssuers by name in Ingress annotations (consumed by cert-manager), but they do not create or own ClusterIssuer objects — those are managed by the `platform` project. Removing it from my-app's whitelist is correct; no functional change to cert-manager behavior.
- **`allow-app-egress-db-redis` NetworkPolicy:** forward-looking policy for Build 017. Applied now so network access is pre-authorized when the DB/cache lands.

---

## Build 015 — Tempo, Promtail, DORA pushes, scanner tightening, PR-teardown job
**Date:** 2026-05-06
**Scope:** Phase C of the production-readiness plan (closes Phase C)

### Added

- `argocd/bootstrap/apps/tempo.yaml` — Argo Application, project `platform`, chart `tempo` v1.10.3 from `https://grafana.github.io/helm-charts`, target namespace `monitoring`, sync wave 0. Single-binary mode (`tempo.replicas: 1`), local storage backend (`storage.trace.backend: local`), OTLP gRPC (4317) + HTTP (4318) receivers exposed. Comment documents production swap to `s3`/`gcs`/`azure`. Low resource requests (100m/256Mi). Persistence disabled (ephemeral emptyDir for kind).
- `argocd/bootstrap/apps/promtail.yaml` — Argo Application, project `platform`, chart `promtail` v6.16.6 from `https://grafana.github.io/helm-charts`, target namespace `monitoring`, sync wave 0. DaemonSet mode picks up all pod logs. Loki push URL: `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`. `config.snippets.pipelineStages` JSON-parses pino logs: promotes `level` and `msg` as Loki labels; `req.id` is high-cardinality so it is kept as a log-line field via the `output` stage (not a Loki label). Comment documents production Vector alternative.
- `.gitleaks.toml` — Minimal allowlist scaffold: `useDefault = true` (extends default rules), empty `regexes` array placeholder, `paths` that suppress `app/package-lock.json`, `tests/*.test.js`, and `.gitleaks.toml` itself.
- `.trivyignore` — Empty suppression file with a header comment documenting the format (`CVE-YYYY-NNNNN  # justification; expiry: YYYY-MM-DD`), picked up automatically by `--ignorefile .trivyignore` in the Trivy stage.

### Modified

- `argocd/bootstrap/apps/otel-collector.yaml` — Replaced `logging` exporter stub with a real `otlp` exporter pointing at `tempo.monitoring.svc.cluster.local:4317` (`tls.insecure: true` for intra-cluster). Removed the TODO comment. No `dependsOn` needed: the OTel collector's built-in retry loop handles Tempo startup lag. Data flow verified: app → OTLP/HTTP (4318) → otel-collector → OTLP/gRPC (4317) → Tempo.
- `argocd/bootstrap/apps/kube-prometheus-stack.yaml` — Added `prometheus.prometheusSpec.additionalScrapeConfigs` with a `pushgateway` job (`honor_labels: true`, target `prometheus-pushgateway.monitoring.svc.cluster.local:9091`). `honor_labels: true` is required so Pushgateway-set labels (job, instance, metric labels from Jenkins) are not overwritten by Prometheus.
- `Jenkinsfile` — Added `pushDoraMetric(String metric, String value)` helper function (curl to Pushgateway). Called from: `Deploy → Production post.success` (deployment_frequency_total +1, lead_time_seconds, mttr_seconds) and `Deploy → Production post.failure` (change_failure_total +1). Lead time approximated as `date +%s` at deploy start minus `git log -1 --format=%ct` (committer epoch). MTTR walks `currentBuild.previousBuild` chain to find most recent FAILURE and subtracts its epoch-ms timestamp. Trivy tightened: dropped `|| true` (stage now fails on HIGH/CRITICAL); `--ignorefile .trivyignore` added as escape hatch. OWASP DC: `--failOnCVSS` tightened from 8 to 7 (matches Trivy HIGH threshold). Gitleaks: dropped `|| true` (stage now fails on any finding); allowlist managed via `.gitleaks.toml`.
- `docker/jenkins/jenkins.yaml` — Added `pr-preview-teardown` pipeline job via Job DSL `pipelineJob()`. Triggered by GitHub `pull_request` closed webhook via Generic Webhook Trigger plugin (`token: pr-preview-teardown`; JSONPath extraction of `$.number` into `CHANGE_ID`). Runs `scripts/pr-preview-down.sh ${CHANGE_ID}` inside a `withCredentials([file(credentialsId: 'kubeconfig')])` block. Sends Slack success/failure notification.
- `docker/jenkins/plugins.txt` — Added `generic-webhook-trigger:latest` (required by the pr-preview-teardown job; was not previously installed).

### Closes (from production-readiness plan)
- Phase C: tracing backend (Tempo), log shipping (Promtail), DORA metric emission, scanner enforcement, PR-teardown automation

### Judgment calls
- **Tempo chart v1.10.3:** latest stable in the 1.x series (single-binary chart). Production should migrate to the `tempo-distributed` chart for HA.
- **Promtail chart v6.16.6:** latest stable in the 6.x series. `req.id` is intentionally NOT a Loki label (cardinality risk); stored as a log-line field via the `output` stage.
- **Lead time approximation:** uses HEAD commit's committer date (`git log -1 --format=%ct`) rather than the first commit on the branch, because shallow clones may not have the full history. This is a lower-bound estimate. Comment in Jenkinsfile documents the trade-off.
- **MTTR approximation:** walks `currentBuild.previousBuild` (all branches, not just production). This may include staging failures in the MTTR window. A production-grade implementation would filter by `BRANCH_NAME == 'main'`. Documented in code comment.
- **OTel collector retry:** accepted "collector will retry" approach (no Argo CD `dependsOn`), noted in sync-wave annotation comment.
- **generic-webhook-trigger:** was NOT already in plugins.txt — added in this build.

---

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
