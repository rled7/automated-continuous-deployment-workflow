# Go-live runbook: one VM with k3s

Everything needed to take this repo from "CI is green" to "Jenkins deploys
`my-app` to staging and production on a cluster you own", in order. Each step
says what to do, how to check it worked, and which file it touches.

The target is **one Linux VM running k3s**: on your laptop first, and later,
by repeating the same steps, on a cloud VM. Everything runs in that one
cluster: Argo CD and the platform, Jenkins and its agents, SonarQube, Postgres
and Redis, staging and production.

> **A laptop is not 24/7.** When the laptop sleeps, production is down. It is
> the right place to prove the whole loop end to end; move to a cloud VM
> (Part 9) when the app needs to stay up.

**Legend:** ☐ do it · 🔑 a secret (never commit it) · ⚠️ not in the repo yet;
the step says what is missing.

---

## Part 0. What you need before you start

### Accounts and tokens

| ☐ | What | Where | Used for |
|---|---|---|---|
| ☐ | 🔑 **GitHub personal access token (classic)**, scopes `repo`, `write:packages`, `read:packages` | GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) | Jenkins reads the repo and creates releases (`github-credentials`); images are pushed to and pulled from `ghcr.io` (`docker-registry-credentials`, `registry-credentials`). Fine-grained tokens cannot push packages, so it has to be a classic one. |
| ☐ | 🔑 **NVD API key** | You already have it | Dependency Vulnerability Scan (`nvd-api-key`) |
| ☐ | 🔑 Slack bot token + workspace *(optional)* | api.slack.com → Your apps | Build notifications (`slack-token`). Without one, the notify step logs a failure and the build carries on. |
| ☐ | Slack incoming webhook *(optional)* | Same app → Incoming Webhooks | Alertmanager alerts (Part 3) |

Keep the secrets in a password manager. They go into the cluster in Parts 4–6
and never into git.

### The VM

| | Minimum | Comfortable |
|---|---|---|
| CPU | 6 vCPU | 8 vCPU |
| Memory | 12 GB | 16 GB |
| Disk | 60 GB | 100 GB |
| OS | Ubuntu Server 24.04 LTS | |

A build runs up to three agent containers of 2 CPU / 4 GiB each next to
everything else, which is why it needs this much.

| VM software | Notes |
|---|---|
| **Multipass** (Windows, macOS, Linux) | Easiest: `multipass launch 24.04 --name cicd --cpus 8 --memory 16G --disk 100G`. The VM gets an IP your laptop can reach (`multipass info cicd`). It has no port forwarding, so use Option B in Part 2. |
| **UTM** (macOS) | Shared or bridged network. ⚠️ **Apple silicon:** the Jenkins agent image is amd64-only (`docker/jenkins-agent/Dockerfile` downloads `linux_amd64` binaries), so agents will not start on an ARM64 VM. Use an Intel/AMD machine, or a cloud VM, until the image is made multi-arch (see "Still to build"). The app image itself is built for both. |
| **VirtualBox** / **VMware** | NAT with port forwards (Option A), or a host-only/bridged adapter (Option B). |
| **Hyper-V** (Windows) | Default Switch gives the VM an IP the host can reach (Option B). |

- ☐ Create the VM and SSH into it.
- ☐ `sudo apt-get update && sudo apt-get install -y git curl jq docker.io && sudo usermod -aG docker $USER` (log out and back in).
- ☐ Clone the repo on the VM: `git clone https://github.com/rled7/automated-continuous-deployment-workflow.git && cd automated-continuous-deployment-workflow`

---

## Part 1. Kubernetes (k3s)

- ☐ Install k3s **without** Traefik and metrics-server. Argo CD installs
  ingress-nginx and metrics-server itself (`argocd/bootstrap/apps/`), and the
  two copies would conflict.
  ```bash
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable metrics-server --write-kubeconfig-mode 600" sh -
  mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown $USER ~/.kube/config
  kubectl get nodes          # one node, Ready
  ```
- ☐ Tools: `kustomize`, `kubeseal`, `cosign` and the `kubectl argo rollouts`
  plugin. `harness/lib/tools.sh` has the pinned versions and download URLs.

Check: `kubectl get storageclass` lists `local-path (default)`. Jenkins,
SonarQube and Postgres put their volumes there.

---

## Part 2. How your laptop reaches the cluster

ingress-nginx listens on the VM's ports **30080** (HTTP) and **30443** (HTTPS)
(`argocd/bootstrap/apps/ingress-nginx.yaml`). The overlays serve
`app.127.0.0.1.nip.io` (production) and `staging.app.127.0.0.1.nip.io`
(staging). Pick one option:

- **Option A: port forwards, no repo change.** In the VM software, forward
  laptop 80 → VM 30080 and laptop 443 → VM 30443. Then the existing hostnames
  work from your laptop's browser as they are.
- **Option B: the VM's IP in the hostnames.** Replace `127.0.0.1` with the
  VM's IP (for example `192.168.64.5`) in:
  - `k8s/overlays/production/ingress-patch.yaml`
  - `k8s/overlays/staging/ingress-patch.yaml`
  - `PREVIEW_DOMAIN` (Part 6)

  Then browse to `https://app.192.168.64.5.nip.io:30443`.

Certificates come from the self-signed issuer, so the browser warns once per
host. Let's Encrypt needs a public hostname and port 80 open to the internet;
that is Part 9.

---

## Part 3. Repo values to set (one commit)

Make these changes on a branch and merge them to `main` first: Argo CD and
Jenkins read the repo from GitHub, not from the VM.

| ☐ | File | Change |
|---|---|---|
| ☐ | `docker/jenkins/jenkins.yaml` | `YOUR_ORG` → `rled7` everywhere. `ghcr.io/YOUR_ORG/jenkins-cicd-agent` → `ghcr.io/rled7/jenkins-cicd-agent`. The job's `repoOwner`/`repositoryUrl`/`url` → `rled7` / `https://github.com/rled7/automated-continuous-deployment-workflow`. |
| ☐ | `policies/kyverno/verify-image-signatures.yaml` | `YOUR_ORG` → `rled7`. The policy is in Audit, so it only reports. See Part 8, day 7. |
| ☐ | `argocd/bootstrap/apps/kube-prometheus-stack.yaml` | Grafana `adminPassword: changeme-bootstrap-only` → your own. Alertmanager receivers: put your Slack webhook in `slack-warnings`/`slack-critical`, or delete the `pagerduty` and `email-fallback` receivers and their routes if you don't use them. |
| ☐ | `argocd/bootstrap/apps/minio.yaml`, `velero.yaml` | `CHANGEME-use-sealed-secret` → one strong password, the same in both files. |
| ☐ | Ingress hosts | Only for Option B in Part 2. |

Check: `harness/verify.sh static` passes. CI runs it on the pull request.

---

## Part 4. Platform (Argo CD + everything it installs)

- ☐ `./scripts/setup.sh --bootstrap-argo`
- ☐ Wait until every application is `Synced` / `Healthy`. On a laptop this
  takes 5–15 minutes, mostly image pulls.
  ```bash
  kubectl get applications -n argocd --watch
  ```
- ☐ 🔑 **Back up the Sealed Secrets key now.** Without it, every sealed secret
  is lost with the VM.
  ```bash
  kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml > sealed-secrets-key-backup.yaml
  ```
  Move the file off the VM into your password manager and delete it from the VM.
- ☐ `kubectl apply -f argocd/AppProject.yaml -f argocd/Application-staging.yaml -f argocd/Application-production.yaml`.
  These Applications are visibility only: Jenkins deploys the app (`argocd/README.md`).

Check:
- Grafana: `kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80` opens with your password.
- `kubectl get pods -n kyverno` are Running.

---

## Part 5. Postgres and Redis for staging and production

⚠️ **Not in the repo yet.**
- The overlays expect a Postgres (`DB_HOST` from `my-app-secrets`, user
  `appuser`, database `appdb`) and a Redis Service (`redis-staging`,
  `redis-production`) in each namespace.
- The repo only has the harness's throwaway versions
  (`harness/fixtures/deps*.yaml`): pods without volumes, which lose all data
  on restart.
- A real setup needs, per namespace:
  - a Postgres StatefulSet on a `local-path` volume;
  - a Redis Deployment;
  - their Services;
  - NetworkPolicies letting `my-app` in.

  The VM bootstrap script will add these (see "Still to build" below).

Production expects TLS to the database (`DB_SSL: "true"` in
`k8s/overlays/production/configmap-patch.yaml`). An in-cluster Postgres has
none, so set it to `"false"` for the VM (the harness does the same,
`db_without_tls`), or give Postgres a certificate.

- ☐ Postgres + Redis running in `staging` and `production`
- ☐ 🔑 A different database password for each

---

## Part 6. Secrets in the cluster

- ☐ `cp .env.example .env` on the VM and fill it in:

  | Variable | Value |
  |---|---|
  | `DOCKER_REGISTRY` | `ghcr.io/rled7` |
  | `DOCKER_USER` / `DOCKER_PASSWORD` | your GitHub username / the classic PAT |
  | `JENKINS_ADMIN_PASSWORD` | 🔑 a new strong password |
  | `SONAR_TOKEN` | after Part 7 (`scripts/sonarqube-setup.sh` prints it) |
  | `NVD_API_KEY` | 🔑 your key |
  | `SLACK_TOKEN` / `SLACK_WORKSPACE` | optional |
  | `GITHUB_USER` / `GITHUB_TOKEN` | your GitHub username / the classic PAT |
  | `STAGING_URL` | `http://my-app.staging.svc.cluster.local` (the agents run in the same cluster) |
  | `PRODUCTION_URL` | `http://my-app.production.svc.cluster.local` |
  | `PREVIEW_DOMAIN` | `127.0.0.1.nip.io` (Option A) or `<VM-IP>.nip.io` (Option B) |
  | `COSIGN_KEY` | see Part 7 |
  | `DB_HOST` / `DB_PASSWORD` | the Postgres Service and password from Part 5 |

  `.env` is in `.gitignore`. Keep it that way, and `chmod 600 .env`.
- ☐ `./scripts/setup.sh --k8s` creates, in `staging` and `production`, the
  `registry-credentials` pull secret and `my-app-secrets`, and applies the
  Pushgateway.

  This writes plain Secrets straight into the cluster. To keep them in git
  instead, seal them (`docs/secrets.md`).
- ☐ Make the GHCR packages private and check that pulls work after the first
  push (Part 7).

Check: `kubectl get secret -n production registry-credentials my-app-secrets` shows both.

---

## Part 7. Jenkins, its agents and SonarQube in the cluster

The Compose stack (`setup.sh --local`) cannot run builds. Jenkins has to run
inside the cluster (README → "Running builds").

### Images

- ☐ Log in to GHCR on the VM: `echo "$GITHUB_TOKEN" | docker login ghcr.io -u <user> --password-stdin`
- ☐ Build and push the agent image:
  ```bash
  docker build -t ghcr.io/rled7/jenkins-cicd-agent:latest docker/jenkins-agent
  docker push ghcr.io/rled7/jenkins-cicd-agent:latest
  ```
- ☐ Build and push the controller: `docker build -t ghcr.io/rled7/jenkins-cicd:latest docker/jenkins`, then push it.
- ☐ Pull secret in namespace `jenkins` for both, if the packages are private.

### Signing key

There is no OIDC identity on a laptop for keyless signing, so use a key:

- ☐ 🔑 `cosign generate-key-pair k8s://jenkins/cosign` creates the Secret
  `cosign` in `jenkins`. Keep the password.
- ☐ `COSIGN_KEY=k8s://jenkins/cosign` in `.env`. Give the `jenkins-agent`
  ServiceAccount `get` on that Secret, and set `COSIGN_PASSWORD` for the
  agents.
- ☐ Publish `cosign.pub` (`kubectl get secret cosign -n jenkins -o jsonpath='{.data.cosign\.pub}' | base64 -d`).
  `verify-image-signatures` will check against it (Part 8, day 7).

### Controller

⚠️ **Not in the repo as a deployable manifest yet.**
`harness/fixtures/jenkins-in-cluster.yaml` is the working shape:
- the namespace, service accounts and RBAC;
- the `jenkins` and `jenkins-agent` Services;
- a Deployment that reads `jenkins.yaml` from ConfigMap `jenkins-casc`, `.env` from Secret `jenkins-env`, and the kubeconfig from Secret `jenkins-kubeconfig`.

`harness/stages/pipeline.sh` (`jenkins_up`) shows every step that fills
them. For real use it is missing:
- a **volume for `/var/jenkins_home`**: without one, every restart loses build history, approvals and the dependency-check cache;
- a **long-lived deploy credential**: the harness makes a 4-hour token;
- a deploy ServiceAccount scoped to `staging`, `production`, `preview-*` and the migration pods, not `cluster-admin`;
- Pod Security `privileged` on namespace `jenkins`, for the dind sidecar.

The bootstrap script will package this. Until then:

- ☐ Namespace `jenkins`, labelled `pod-security.kubernetes.io/enforce=privileged`
- ☐ `kubectl -n jenkins create configmap jenkins-casc --from-file=jenkins.yaml=docker/jenkins/jenkins.yaml`
- ☐ `kubectl -n jenkins create secret generic jenkins-env --from-env-file=.env`
- ☐ Secret `jenkins-kubeconfig`: a kubeconfig for the deploy ServiceAccount (server `https://kubernetes.default.svc`)
- ☐ The fixture with your controller image and a PVC for `/var/jenkins_home`

### SonarQube

⚠️ The harness starts a throwaway one (`sonar_up`). `jenkins.yaml` expects it at
`http://sonarqube:9000`, a Service named `sonarqube` in namespace `jenkins`.

- ☐ SonarQube 10.7 Community with its own Postgres and a volume
- ☐ First login `admin`/`admin`, set a password, then `SONAR_ADMIN_PASSWORD=… scripts/sonarqube-setup.sh`.
  It creates the token and the quality-gate webhook to Jenkins.
- ☐ Put `SONAR_TOKEN` in `jenkins-env` and restart Jenkins.

Check:
- `kubectl -n jenkins port-forward svc/jenkins 8080:8080`, then log in as `admin`.
- Manage Jenkins → Credentials lists all seven IDs (README → "Configure Jenkins").
- The `my-app` multibranch job exists and has scanned the repository.

---

## Part 8. GitHub, then the first deploys

### GitHub

- ☐ Create the `develop` branch from `main` (the repo has none yet). Staging deploys from `develop`.
- ☐ Branch protection on `main` and `develop`: require pull requests, and require the `verify` checks to pass.
- ☐ **Webhooks: optional.** GitHub cannot reach a laptop.
  - Jenkins rescans the repository every 5 minutes (`periodicFolderTrigger`), so pushes are built within 5 minutes without any webhook.
  - The exception is PR preview **teardown**: it runs on GitHub's `pull_request closed` webhook. Without a webhook, delete previews by hand with `scripts/pr-preview-down.sh <PR number>`.
  - To get instant builds and automatic teardown, expose Jenkins through a tunnel (Cloudflare Tunnel or ngrok) and add two webhooks:
    - `https://<tunnel>/github-webhook/` (push and pull request events);
    - `https://<tunnel>/generic-webhook-trigger/invoke?token=pr-preview-teardown` (pull request events, for teardown).

### First staging deploy (`develop`)

- ☐ Push a commit to `develop`, or wait for the scan.
- ☐ Watch the build in Jenkins. Every stage should pass, including Deploy →
  Staging, migrations, smoke, performance and E2E tests.
- ☐ Open `https://staging.app.127.0.0.1.nip.io` (or your Option B host). `/health` returns 200.

### First production deploy (`main`)

- ☐ Merge `develop` into `main`.
- ☐ The build stops at the approval gate. Approve it in Jenkins.
- ☐ Watch the canary.
  ```bash
  kubectl argo rollouts get rollout my-app -n production --watch
  ```
  The analysis must report measurements, not errors: the query requires real
  traffic data. On a quiet laptop, send some requests to the production host
  while it runs.
- ☐ The smoke tests run read-only against production.
- ☐ Grafana shows the DORA metrics from the Pushgateway.
- ☐ Tick "First production deploy … watched" in `CHANGELOG.md`. On a new
  cluster there is no stray Deployment to remove.

### First release (tag)

- ☐ `./scripts/release.sh 0.1.0`, then `git push --follow-tags`
- ☐ The tag build tags the image `v0.1.0` in GHCR and creates the GitHub release (`docs/RELEASING.md`).

### Rollback drill (before you rely on it)

- ☐ Deploy a release, then roll back with `kubectl argo rollouts undo my-app -n production` and check the previous image serves again.
- ☐ Abort a canary mid-way (`kubectl argo rollouts abort my-app -n production`) and check that stable traffic is unaffected.

---

## Part 9. After go-live

| When | ☐ | What |
|---|---|---|
| Day 1 | ☐ | Alerts reach Slack: fire a test alert from Alertmanager. |
| Day 1 | ☐ | Velero backups run (`velero backup get`). They land in MinIO **on the same VM**, so copy them off it, or point Velero at off-site storage (`argocd/bootstrap/apps/velero.yaml`). |
| Day 1 | ☐ | The Sealed Secrets key backup and `.env` are in your password manager, not on the VM. |
| Day 7 | ☐ | Promote `verify-image-signatures` to Enforce (`docs/policy-promotion.md`). It is written for keyless signing; with the key from Part 7, change its attestor to that public key first, then check `kubectl get policyreports -A` shows no failures for `my-app` images. |
| Day 7 | ☐ | Point the dependency-check database at a volume and run the nightly update job (`jenkins.yaml`, `DEPENDENCY_CHECK_DATA`). Builds then skip the NVD download. |
| Later | ☐ | **Move to a cloud VM** for 24/7 uptime. Same steps on any provider's Ubuntu VM. Then: <ul><li>change the ingress-nginx Service to `LoadBalancer`, or keep NodePort and open 80/443;</li><li>use real hostnames in the ingress patches with `letsencrypt-prod` and your email in `argocd/bootstrap/issuers/`;</li><li>add webhooks to the public Jenkins URL;</li><li>restore the Sealed Secrets key before syncing (`docs/secrets.md`).</li></ul> |

---

## Still to build in the repo

These are the ⚠️ steps above. Together they would let one script do Parts 1, 4,
5 and 7:

1. **Postgres + Redis per environment**: StatefulSet/Deployment with volumes,
   Services named as the overlays expect, NetworkPolicies, and `DB_SSL` handled
   for an in-cluster database.
2. **Jenkins for real use**:
   - the fixture plus a `jenkins_home` volume, a scoped deploy ServiceAccount
     with a long-lived token, and the `privileged` namespace label;
   - the cosign Secret wiring (RBAC and `COSIGN_PASSWORD`);
   - images from GHCR.
3. **SonarQube with persistence**, as the Service `sonarqube` in `jenkins`.
4. **A multi-arch agent image**: `TARGETARCH` in place of the hard-coded
   `amd64` downloads, so agents run on Apple-silicon VMs.
5. **`scripts/vm-bootstrap.sh`**: k3s with the right flags, the tools, Argo CD,
   1–3, the secrets from `.env`, and a check at the end.
