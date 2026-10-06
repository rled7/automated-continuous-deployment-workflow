# Verification harness

One command that checks a change the way you would by hand: render and lint the
Kubernetes manifests, test and build the app, run it as a pod with its real
security settings next to a database, apply it to a (simulated or real)
cluster, and exercise Terraform against a local AWS. No cloud account,
credentials or long-lived cluster needed.

It is written for both people and agents: every run leaves a machine-readable
`harness/.results/results.json` with a pass/fail per stage and step, plus a log
per stage.

```bash
harness/verify.sh --list          # what each stage does
harness/verify.sh                 # default stages
harness/verify.sh static pod      # just these
KEEP=1 harness/verify.sh pod      # leave containers/clusters up to poke at
```

## Stages

| Stage | What it proves | Needs |
|---|---|---|
| `static` | Overlays render as Jenkins deploys them (`kustomize edit set image`); schemas valid (incl. Argo Rollouts CRDs); cross-object sanity (duplicate controllers, HPA targets, selectors); the repo's Kyverno policies pass | — |
| `app` | `npm ci`, lint, unit tests — same commands as the pipeline | Node 20 |
| `image` | `docker/Dockerfile` builds, runtime dependencies are really in the image, runs as non-root | Docker |
| `pod` | The rendered staging Deployment runs under `podman kube play` with its ConfigMap, Secret, read-only root filesystem and uid; migrations as `runMigrations()` runs them; startup/readiness probes; smoke tests | Docker, podman |
| `cluster-sim` | Every overlay is accepted by a real Kubernetes API server (KWOK: simulated nodes); Deployments roll out; HPA targets exist | — |
| `terraform` | Each module in `TF_DIRS`: fmt, validate, `terraform test`, apply, no drift, destroy — against [Floci](https://github.com/floci-io/floci) (local AWS) | Docker |
| `cluster-real` (opt-in) | Staging deployed to a real kind cluster exactly as the Jenkinsfile does it, NetworkPolicies enforced, smoke tests through the Service | Docker, a host where kind works |

Steps keep going after a failure so one run reports everything it can. Where
a pipeline step fails (for example migrations), the stage records the failure
and falls back to a working equivalent so later steps still say something.

Tools (kubectl, kustomize, kubeconform, kyverno, kwok, kind, terraform) are
downloaded at pinned versions into `harness/.bin` on first use.

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

- **Your machine**: everything, including `cluster-real`.
- **GitHub Actions**: `.github/workflows/verify.yml` runs all stages on every
  PR and on demand, and uploads `harness/.results` as an artifact.
- **Claude Code cloud sessions**: everything except `cluster-real` (the sandbox
  does not allow the negative OOM scores Kubernetes gives its pods, so kind and
  k3s pods never start). HTTPS there is intercepted; the image stage
  auto-detects the sandbox CA so `npm ci` inside `docker build` works.

Docker Hub rate-limits shared IPs, so official images are pulled through
`mirror.gcr.io` (`IMAGE_MIRROR` to change).
