# Custom Jenkins Agent Image

The Jenkinsfile invokes a long list of CLIs (`kubectl`, `kustomize`, `kubeconform`, `gitleaks`, `syft`, `cosign`, `trivy`, `dependency-check.sh`, `k6`, `gh`, plus `node` and `npm`). On a stock `jenkins/inbound-agent` image none of these exist, so Jenkins stages would fail with `command not found`.

This directory builds a custom agent image that bundles every required CLI, and the Jenkinsfile + JCasC config wire Jenkins to launch agents from that image inside a Kubernetes pod template.

## What's in the image

| Tool | Used by Jenkinsfile stage |
|---|---|
| `node`, `npm` | Build, Test, Lint |
| `kubectl` | Validate Manifests, Deploy → Staging, Deploy → Production, Deploy → PR Preview |
| `kustomize` | Validate Manifests, Deploy stages |
| `kubeconform` | Validate Manifests |
| `gitleaks` | Code Quality & Security → Gitleaks |
| `syft` | Docker Build & Push → SBOM |
| `cosign` | Docker Build & Push → image signing |
| `trivy` | Docker Build & Push → image vuln scan |
| `dependency-check.sh` | Code Quality & Security → Dependency Vulnerability Scan |
| `k6` | Performance Tests |
| `gh` | Release |

Tool versions are pinned via `ENV` lines at the top of `Dockerfile`. Bump them in their own commits so Renovate / Dependabot can track them.

## Build

```bash
docker build \
  -t ghcr.io/<ORG>/jenkins-cicd-agent:<TAG> \
  -f docker/jenkins-agent/Dockerfile \
  docker/jenkins-agent
```

Suggested tagging: `<NODE_VERSION>-<GIT_SHORT_SHA>` (for example `20.18.1-a1b2c3d`). Promote the tag through your registry the same way you'd promote any other image.

## Push

```bash
docker push ghcr.io/<ORG>/jenkins-cicd-agent:<TAG>
```

`ghcr.io` is the suggested registry because `gh auth login` already grants the necessary token; substitute Docker Hub, ECR, GAR, or Harbor as appropriate.

## Use

1. Update `docker/jenkins/jenkins.yaml` — `jenkins.clouds.kubernetes.templates[0].containers[0].image` — to reference the pushed tag.
2. Apply the JCasC change (Argo CD will sync it if Jenkins runs in-cluster, otherwise restart the Jenkins controller pod).
3. The `Jenkinsfile` already declares `agent { kubernetes { ... } }`, so subsequent builds will spawn pods from the new image automatically.

## Caveats

- **Image is amd64-only.** If you run Jenkins controllers on arm64 (Graviton, Ampere), build a multi-arch image with `docker buildx build --platform linux/amd64,linux/arm64`.
- **Docker socket mounting** is the default in the pod template (so `docker build`/`docker push` in the Jenkinsfile work). For tighter security in production, switch to `kaniko` or `buildah` and remove the docker socket mount.
- **Image size** is large (~1.5 GB). That's the cost of bundling Java + JDK + Node + a dozen CLIs. Acceptable for build agents; not what you'd ship to production.
- **No JDK17 separately for OWASP Dependency Check** — it uses the JDK already in the base image.
- **Pinned versions can drift.** Set up a weekly Renovate rule for `docker/jenkins-agent/Dockerfile` to track upstream releases.

## Local testing

To verify the image works end-to-end without spinning up a full Jenkins cluster:

```bash
docker run --rm -it \
  --entrypoint bash \
  ghcr.io/<ORG>/jenkins-cicd-agent:<TAG> \
  -c "kubectl version --client && kustomize version && trivy --version && cosign version"
```

If any tool reports an error, the `Sanity check` step in `Dockerfile` should have caught it — failing builds early is the point.
