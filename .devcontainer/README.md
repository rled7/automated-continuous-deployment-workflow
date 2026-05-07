# Dev Container

VS Code's [Dev Containers](https://containers.dev/) extension reads `devcontainer.json` and spins up a Debian container with every tool this repo uses preinstalled.

## What's in the box

| Tool | Why |
|---|---|
| `node` 20 | Run the app, run tests |
| `docker` (in-docker) | Build images locally |
| `kubectl`, `helm`, `kustomize` | Cluster operations |
| `kind` | Local Kubernetes cluster |
| `kubeseal` | Seal secrets via the workflow in `docs/secrets.md` |
| `skaffold` | Hot-reload dev against the cluster |
| `trivy`, `cosign`, `syft` | Image scanning + signing + SBOM |
| `gh` | GitHub CLI for branch protection + releases |
| VS Code extensions: ESLint, Prettier, Docker, Kubernetes, YAML, GitHub Actions, Playwright, EditorConfig | IDE integration |

`.husky/pre-commit` and `.husky/commit-msg` hooks fire automatically on `git commit` once `npm install` runs (the `prepare` script does it via `postCreateCommand`).

## Usage

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers).
2. `code .` from the repo root.
3. VS Code prompts: **Reopen in Container**. Click yes.
4. First boot takes 5–10 minutes (downloads features). Subsequent opens are instant.

## What's mounted

- `~/.kube` from the host → `/home/vscode/.kube` in the container, so cluster context persists across sessions.

## Caveats

- Docker-in-Docker burns extra resources; if your laptop is constrained, comment out the `docker-in-docker` feature and use the host's docker socket via `mounts: [-source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind]` instead.
- The `kubeseal`, `skaffold`, etc. dev-container features come from community-maintained registries (`devcontainers-contrib`, `dhoeric`). Pin specific versions in `devcontainer.json` if you need reproducibility.
