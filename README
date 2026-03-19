# Jenkins CI/CD Pipeline — 24/7 Auto-Deploy

A fully automated CI/CD pipeline: every `git push` triggers build → test → deploy → rollback (if anything fails). Zero manual intervention in production.

---

## Architecture

```
Developer Push
     │
     ▼
┌─────────────┐    Webhook    ┌──────────────────────────────────────────────┐
│   GitHub    │──────────────▶│              Jenkins Pipeline                │
└─────────────┘               │                                              │
                               │  1. Checkout                                 │
                               │  2. Lint + SonarQube + Vuln Scan (parallel) │
                               │  3. Build (npm run build)                    │
                               │  4. Unit Tests + Integration Tests (parallel)│
                               │  5. Docker Build + Trivy Scan + Push         │
                               │  6. Deploy → Staging (develop branch)        │
                               │  7. Performance Tests (k6)                   │
                               │  8. Deploy → Production (main branch)        │
                               │     └─ Auto-rollback on failure              │
                               └──────────────────────────────────────────────┘
```

---

## Project Structure

```
jenkins-cicd/
├── Jenkinsfile                  # Full pipeline definition
├── .env.example                 # Environment variables template
├── app/
│   └── src/
│       ├── server.js            # Express app with graceful shutdown
│       └── routes/health.js     # /health/live + /health/ready endpoints
├── docker/
│   ├── Dockerfile               # Multi-stage production image
│   └── docker-compose.yml       # Local Jenkins + SonarQube + Registry
├── jenkins/
│   ├── jenkins.yaml             # Jenkins Configuration as Code (JCasC)
│   └── plugins.txt              # Required Jenkins plugins
├── k8s/
│   ├── production/deployment.yaml   # HPA, PDB, rolling update, ingress
│   └── staging/deployment.yaml
├── monitoring/
│   └── prometheus.yaml          # Prometheus scrape + alert rules
├── tests/
│   ├── performance/load-test.js # k6 load test (ramp → spike → ramp down)
│   └── smoke/smoke.test.js      # Post-deploy smoke tests
└── scripts/
    └── setup.sh                 # Bootstrap script
```

---

## Quick Start

### 1. Clone & Configure

```bash
git clone https://github.com/YOUR_ORG/my-app
cd jenkins-cicd
cp .env.example .env
# Edit .env with your credentials
```

### 2. Start Local CI Stack

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh --local
```

Opens:
- Jenkins  → http://localhost:8080
- SonarQube → http://localhost:9000

### 3. Configure Jenkins

Jenkins auto-configures itself via `jenkins/jenkins.yaml` (JCasC). Add these credentials manually in **Manage Jenkins → Credentials**:

| ID | Type | Description |
|----|------|-------------|
| `docker-registry-credentials` | Username/Password | Docker registry |
| `kubeconfig` | Secret file | Kubernetes config |
| `sonarqube-token` | Secret text | SonarQube token |
| `slack-token` | Secret text | Slack bot token |
| `github-credentials` | Username/Password | GitHub PAT |

### 4. Set Up Kubernetes (Production)

```bash
./scripts/setup.sh --k8s
```

### 5. Push to Trigger the Pipeline

```bash
git checkout -b develop
git push origin develop   # → triggers staging deploy

git checkout main
git merge develop
git push origin main      # → triggers production deploy (with approval gate)
```

---

## Pipeline Stages

| Stage | What it does | Fails pipeline? |
|-------|-------------|-----------------|
| Checkout | Pulls code, sets env vars | Yes |
| SonarQube | Code quality gate | Yes |
| Dependency Scan | OWASP CVE check (CVSS ≥ 8) | Yes |
| Lint | ESLint | No (warns) |
| Build | `npm run build` | Yes |
| Unit Tests | Jest + coverage (≥80%) | Yes |
| Integration Tests | Jest integration suite | Yes |
| Docker Build | Multi-stage build | Yes |
| Trivy Scan | Container image CVE scan | No (warns) |
| Deploy → Staging | Rolling update to staging | Yes |
| Performance Tests | k6 (p95 < 500ms, error rate < 1%) | Yes |
| Deploy → Production | Rolling update, manual approval | Yes |
| **Auto-Rollback** | **Reverts production on failure** | — |

---

## 24/7 Reliability Features

- **Rolling updates** — `maxUnavailable: 0` means zero downtime deploys
- **Liveness/Readiness probes** — Kubernetes only routes traffic to healthy pods
- **HPA** — Auto-scales from 3 → 20 pods based on CPU/memory
- **Pod Disruption Budget** — Guarantees ≥2 pods available during node maintenance
- **Graceful shutdown** — SIGTERM handler closes connections cleanly in 55s
- **Automatic rollback** — If production deploy fails, Jenkins reverts to previous image automatically
- **Prometheus alerts** — Pages on-call if error rate, latency, or pod restarts spike

---

## Rollback

**Automatic** (triggered on pipeline failure):
```
Jenkins detects deploy failure → kubectl set image → previous image → done
```

**Manual** (any time):
```bash
# Roll back to previous revision
kubectl rollout undo deployment/my-app --namespace=production

# Roll back to specific revision
kubectl rollout undo deployment/my-app --to-revision=3 --namespace=production

# Check rollout history
kubectl rollout history deployment/my-app --namespace=production
```

---

## Branch Strategy

| Branch | Deploys to | Gate |
|--------|-----------|------|
| `feature/*` | (none) | Tests only |
| `develop` | Staging | All tests + perf tests |
| `main` | Production | Manual approval + all tests |



--------------------------------------------------------------------------------------------------------------------------------------------------------------


CI/CD Orchestration
Jenkins
The core pipeline engine. Every git push triggers the full build → test → deploy → rollback sequence automatically. Chosen over GitHub Actions or GitLab CI because Jenkins is self-hosted (full control over secrets, no vendor lock-in), has a massive plugin ecosystem, and is the industry standard in enterprise DevOps environments — which matches the diagram you shared.

Application Runtime
Node.js 20 (LTS)
The application server runtime. Chosen over Python/Django or Java/Spring because it's lightweight, has excellent container startup times (critical for rolling deploys), and the async I/O model handles high-concurrency API traffic efficiently with minimal memory.
Express.js
The HTTP framework powering the app and health endpoints. Chosen over Fastify or NestJS for its simplicity — the pipeline demo doesn't need an opinionated framework, and Express has zero overhead for exposing the /health/live and /health/ready endpoints Kubernetes depends on.

Containerization
Docker
Packages the app and all its dependencies into a portable, reproducible image. Chosen universally — there's no real alternative here for container-based deployments.
Multi-stage Dockerfile
A specific Docker pattern used to keep the final production image small. The build tools and dev dependencies are used in earlier stages and thrown away — only the compiled output and production node_modules end up in the final image. Alternatives like single-stage builds produce images 3–5x larger.
Docker Compose
Used to run the local development infrastructure (Jenkins, SonarQube, PostgreSQL, Redis, local registry) as a single stack. Chosen over running everything manually because one command (docker-compose up) boots the entire CI environment reproducibly.

Container Orchestration
Kubernetes
Manages running the application in production — scheduling pods across nodes, health checking, auto-scaling, and rolling out new versions with zero downtime. Chosen over Docker Swarm or plain EC2 because it has native rolling update strategies, the HPA for autoscaling, and Pod Disruption Budgets for maintenance safety. It's also the production standard at scale.
Kubernetes Manifests (YAML)
The declarative configuration files that describe everything Kubernetes needs to know: deployment strategy, resource limits, probes, ingress rules, and autoscaling policies. Chosen over Helm charts to keep the codebase simple and readable — Helm adds significant complexity that isn't needed unless you're managing many environments with shared templates.

Code Quality & Security
SonarQube
Static analysis tool that scans code for bugs, code smells, and security vulnerabilities before any build or deploy happens. If the Quality Gate fails, the pipeline stops. Chosen over ESLint alone because SonarQube goes far deeper — it tracks technical debt, detects security hotspots (like hardcoded secrets or SQL injection risks), and gives a pass/fail gate Jenkins can enforce.
OWASP Dependency Check
Scans node_modules against the National Vulnerability Database for known CVEs. Fails the pipeline if any dependency has a CVSS score of 8 or higher (High/Critical). Chosen over Snyk because it's free, open source, and runs entirely on-premises with no data leaving your environment.
Trivy
Scans the built Docker image for OS-level and library vulnerabilities before it's pushed to the registry. Chosen over Clair or Anchore because Trivy is significantly faster, has no server component to maintain, and produces very low false-positive rates.
ESLint
JavaScript linter that catches syntax errors, style violations, and common anti-patterns at the source level — the fastest and cheapest check in the pipeline. Chosen over JSHint or TSLint (deprecated) because it's the current standard with the broadest plugin ecosystem.

Testing
Jest
The unit and integration test runner. Produces JUnit XML reports Jenkins can consume, and generates Cobertura-format coverage reports with an 80% line coverage threshold. Chosen over Mocha/Chai because Jest bundles the test runner, assertion library, mocking, and coverage in a single tool with zero configuration.
k6
Load and performance testing tool that runs against staging after every deploy to staging. Enforces SLA thresholds: p95 response time under 500ms, error rate under 1%. Chosen over JMeter because k6 tests are written in plain JavaScript, it produces clean JSON output Jenkins can archive, and it's dramatically faster and lighter to run in CI than JMeter's Java/XML setup.
Smoke Tests (Jest + Axios)
Lightweight post-deploy tests that run immediately after each deployment to verify the app is actually serving traffic correctly. Fast on purpose — they check health endpoints, a core API route, and response time, then exit. A separate concern from unit tests because they test the live deployed environment, not isolated code.

Infrastructure & Networking
NGINX Ingress Controller
Routes external HTTPS traffic into the Kubernetes cluster and to the correct service. Handles TLS termination, rate limiting, and redirects. Chosen over AWS ALB Ingress or Traefik because NGINX Ingress is cloud-agnostic (works the same on AWS, GCP, Azure, or bare metal) and has the most mature feature set.
cert-manager
Automatically provisions and renews TLS certificates from Let's Encrypt. Chosen because it makes HTTPS completely hands-off — no manual certificate renewals ever.

Monitoring & Alerting
Prometheus
Scrapes metrics from application pods and Kubernetes nodes on a 15-second interval. Evaluates alert rules continuously. Chosen over Datadog or New Relic because it's open source, self-hosted, and the de facto standard for Kubernetes monitoring.
Grafana (referenced as the dashboard layer for Prometheus)
Visualizes Prometheus metrics in dashboards. Chosen over Kibana because Kibana is optimized for log data whereas Grafana is built specifically for time-series metrics from Prometheus.
Alertmanager
Receives firing alerts from Prometheus and routes them to Slack. Handles deduplication so you don't get spammed with the same alert every 15 seconds. Part of the Prometheus ecosystem — no meaningful alternative when running Prometheus.

Configuration & Secrets
Jenkins Configuration as Code (JCasC)
Defines Jenkins' entire configuration — credentials, tools, jobs, plugins, authorization — in a single YAML file that's version-controlled. Chosen over manual UI configuration because it makes Jenkins fully reproducible: destroy and rebuild the Jenkins server and it comes back identical with one file.
Kubernetes Secrets
Stores sensitive values (database passwords, API keys) as encrypted objects in the cluster, injected into pods as environment variables at runtime. The alternative — hardcoding secrets in Docker images or YAML files — is a serious security vulnerability.
Kubernetes ConfigMaps
Stores non-sensitive configuration (Redis URL, feature flags) separately from the application image, so config can change without rebuilding the container.

Notifications
Slack (Jenkins Slack Plugin)
Sends pipeline status messages (started, success, failure, rollback) to a designated channel in real time. Chosen over email because it's immediate, visible to the whole team, and actionable — you see a failure and can click through to the Jenkins build in seconds.