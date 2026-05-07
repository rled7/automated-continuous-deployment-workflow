# Local Development with Skaffold

`skaffold.yaml` at the repo root enables a fast inner-loop development experience against a local Kubernetes cluster.

## Prerequisites

| Tool       | Purpose                                    | Install                              |
|------------|--------------------------------------------|--------------------------------------|
| Docker     | Build container images                     | https://docs.docker.com/get-docker/  |
| kind / k3d / minikube | Local Kubernetes cluster        | https://kind.sigs.k8s.io / https://k3d.io / https://minikube.sigs.k8s.io |
| kubectl    | Cluster interaction                        | https://kubernetes.io/docs/tasks/tools/ |
| kustomize  | Manifest generation (used by Skaffold)     | https://kubectl.docs.kubernetes.io/installation/kustomize/ |
| skaffold   | Build + deploy + sync orchestration        | https://skaffold.dev/docs/install/   |

## Quick start

```bash
# 1. Start a local cluster (example using kind)
kind create cluster --name dev

# 2. Create the dev namespace
kubectl create namespace dev

# 3. Run Skaffold in watch mode — rebuilds & redeploys on file changes
skaffold dev --namespace dev
```

Skaffold will:
- Build `my-app` image from `app/` using `docker/Dockerfile`
- Deploy the staging overlay (`k8s/overlays/staging`) into the `dev` namespace
- Port-forward `service/my-app:3000` → `localhost:3000`
- **Hot-sync** any `app/src/**/*.js` change directly into the running container (no image rebuild)

## Commands

| Command                          | Effect                                              |
|----------------------------------|-----------------------------------------------------|
| `skaffold dev --namespace dev`   | Live-reload loop; Ctrl-C tears everything down      |
| `skaffold run --namespace dev`   | One-shot build + deploy (no watch, no teardown)     |
| `skaffold delete --namespace dev`| Remove all deployed resources                       |
| `skaffold build`                 | Build the image only (no deploy)                    |
| `skaffold debug --namespace dev` | Like `dev` but injects debugger and exposes ports   |

## File sync (hot reload)

Any `*.js` file under `app/src/` is synced into the container at the same relative path (`/app/src/`) without triggering a rebuild. If your runtime supports hot-module replacement (e.g., nodemon), changes appear in seconds.

Files outside `app/src/` (package.json, Dockerfile, k8s manifests) trigger a full rebuild + redeploy cycle.

## Skaffold vs Argo CD — inner loop vs outer loop

| Concern              | Skaffold (inner loop)          | Argo CD (outer loop)                  |
|----------------------|--------------------------------|---------------------------------------|
| Who uses it          | Individual developer           | CI/CD pipeline + GitOps automation    |
| Trigger              | Local file save                | Git push to main                      |
| Target cluster       | Local (kind/k3d/minikube)      | Production / staging cluster          |
| Namespace            | `dev` (per developer)          | `production`, `staging`               |
| Image registry       | Local daemon (no push)         | Remote registry (e.g., GHCR, ECR)    |
| Rollback             | `Ctrl-C` (skaffold dev)        | Argo CD `App diff + sync` or git revert |

Skaffold and Argo CD are complementary: use Skaffold to iterate quickly on your laptop, and let Argo CD take over once code is pushed to the repository.

## Overriding the kube context

```bash
skaffold dev --namespace dev --kube-context kind-dev
```

Alternatively set `kubeContext` in `skaffold.yaml` to pin to a specific cluster.
