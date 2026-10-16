# Verification harness

One command that checks a change the way you would by hand: render and lint the
Kubernetes manifests, test and build the app, run it as a pod with its real
security settings next to a database, apply it to a (simulated or real)
cluster, and exercise Terraform against a local AWS. No cloud account,
credentials or long-lived cluster needed.

It is written for both people and agents: every run leaves a machine-readable
`harness/.results/results.json` with a pass/fail per stage and step, plus a log
per stage. A failed step also carries the last 30 lines of its output
(`output_tail`), and the terminal shows the end of it under the step, so the
cause is usually visible without opening the log.

```bash
harness/verify.sh --list          # what each stage does
harness/verify.sh                 # default stages
harness/verify.sh static pod      # just these
KEEP=1 harness/verify.sh pod      # leave containers/clusters up to poke at
harness/verify.sh cluster-real cluster-prod   # the opt-in real-cluster stages
```

## Stages

| Stage | What it proves | Needs |
|---|---|---|
| `static` | Overlays render as Jenkins deploys them (`kustomize edit set image`); schemas valid (incl. Argo Rollouts CRDs); cross-object sanity (duplicate controllers, HPA targets, selectors); the repo's Kyverno policies pass | — |
| `app` | `npm ci`, lint, unit tests — same commands as the pipeline | Node 20 |
| `image` | `docker/Dockerfile` builds, runtime dependencies are really in the image, runs as non-root | Docker |
| `pod` | The rendered staging Deployment runs under `podman kube play` with its ConfigMap, Secret, read-only root filesystem and uid; migrations as `runMigrations()` runs them; startup/readiness probes; smoke tests | Docker, podman |
| `cluster-sim` | Every overlay is accepted by a real Kubernetes API server (KWOK: simulated nodes); every workload's pod template and the migration pod pass Pod Security admission ("restricted"); Deployments roll out; HPA targets exist | — |
| `jenkins` | Jenkins built from `docker/jenkins/Dockerfile` (your `plugins.txt`) starts with `jenkins.yaml` applied; the jobs it defines exist; every credential the Jenkinsfile uses is defined; every agent block (the Jenkinsfile's, inline jobs', and one of each syntax in `fixtures/agent-forms.Jenkinsfile`) resolves, through Jenkins' parser and the Kubernetes plugin's own code, to a pod whose steps run in the agent image next to Docker ([docs/agent-resolution.md](../docs/agent-resolution.md)); Jenkins' own declarative validator accepts the Jenkinsfile. The agent image (`docker/jenkins-agent/Dockerfile`) builds and has every command the pipeline calls (~2 min after the first build) | Docker |
| `terraform` | Each module in `TF_DIRS`: fmt, validate, `terraform test`, apply, no drift, destroy — against [Floci](https://github.com/floci-io/floci) (local AWS) | Docker |
| `cluster-real` (opt-in) | Staging deployed to a real kind cluster exactly as the Jenkinsfile does it, with Pod Security and NetworkPolicies enforced; smoke tests through the Service | Docker, a host where kind works |
| `cluster-prod` (opt-in) | The Jenkinsfile's production path on kind with the Argo Rollouts controller: starting from a pre-fix cluster (stray Deployment), deploy and wait with `scripts/wait-for-rollout.sh`, remove the stray Deployment, smoke tests; then a release whose canary fails must be reported, rolled back with `rollback()`, and serve the previous image again (~5 min) | Docker, a host where kind works |
| `pipeline` (opt-in) | The Jenkinsfile itself, run by Jenkins: the controller (`docker/jenkins`, `jenkins.yaml`) runs inside kind, launches `cicd-agent` pods from the agent image, and builds this working tree as `$PIPELINE_BRANCH` (default `develop`) from a git server in the cluster. Each Jenkins stage is recorded as a step (pass, fail with its output, or skip); the console log is in `logs/pipeline-console.log`. Then the `agent-forms` job runs one stage per way of asking for an agent and checks each pod has the tools and Docker (`agent form: <stage>` steps). Stand-ins: a local registry, placeholder secrets, an in-cluster kubeconfig | Docker, a host where kind works |

Steps keep going after a failure so one run reports everything it can. Where
a pipeline step fails (for example migrations), the stage records the failure
and falls back to a working equivalent so later steps still say something.

Images are built with the sandbox's CA added to their build stages only, so
npm and Java downloads work where HTTPS is intercepted.

Tools (kubectl, kustomize, kubeconform, kyverno, kwok, kind, terraform) are
downloaded at pinned versions into `harness/.bin` on first use.

In `cluster-prod` the canary fails because the harness runs no Prometheus: the
success-rate analysis errors and Argo aborts the rollout. That tests the
failure → rollback path, not the analysis query itself.

The real-cluster stages apply each overlay's Namespace (with its Pod Security
labels) before anything else, as a long-lived cluster has it, so every pod,
including the throwaway Postgres/Redis and the migration pod, is admitted
against "restricted".

## Terraform

Modules need no harness-specific code. Each module is copied to a temp dir and
an override file points the `aws` provider at Floci and replaces any remote
backend with local state:

```bash
TF_DIRS="infra/network infra/eks" harness/verify.sh terraform
```

Emulators are not AWS: IAM is not enforced and some services are partial (in
Floci 2.2.0, deleting an ECR repository fails). Use this for fast feedback and
a real sandbox account for the final check.

## Where it runs

- **Your machine**: everything, including `cluster-real` and `cluster-prod`.
- **GitHub Actions**: `.github/workflows/verify.yml` runs on every PR, on
  pushes to `main` and on demand. Stage groups run as parallel jobs (checks,
  terraform, jenkins, cluster-real, cluster-prod, pipeline), so the workflow
  takes as long as the slowest group rather than the sum of all stages.
  - **Skipping what already passed.** Each group lists the files its stages
    read (`inputs` in the workflow's matrix). Their git blob hashes, plus the
    harness itself and the ISO week, make a key. A group whose key belongs to
    a run that passed is skipped in seconds, so a docs-only change skips
    everything and a Terraform change runs only `terraform`. A new week
    re-runs everything, which re-checks floating base images. To run every
    group anyway, start the workflow by hand with `force`. When a stage starts
    reading a new path, add it to its group's `inputs`.
  - **Caches for the groups that run:** Docker layers
    (`HARNESS_DOCKER_CACHE=gha` in `docker_build`), the pinned tools in
    `harness/.bin`, Terraform providers, npm packages, and dependency-check's
    vulnerability database (`harness/.cache/dependency-check`, mounted into
    the agent pods of the `pipeline` stage, so the scan updates it instead of
    downloading all of NVD).

  Each job prints its steps in the run summary, the logs of failed stages, and
  uploads `harness/.results` as an artifact.
- **Claude Code cloud sessions**: everything except `cluster-real`,
  `cluster-prod` and `pipeline` (the sandbox does not allow the negative OOM scores Kubernetes
  gives its pods, so kind and k3s pods never start). The SessionStart hook
  (`.claude/hooks/session-start.sh`) installs the npm dependencies, podman and
  the pinned tools and starts Docker, so the harness runs straight away. HTTPS
  there is intercepted; the image stage auto-detects the sandbox CA so `npm ci`
  inside `docker build` works.

Docker Hub rate-limits shared IPs, so official images are pulled through
`mirror.gcr.io` (`IMAGE_MIRROR` to change).
