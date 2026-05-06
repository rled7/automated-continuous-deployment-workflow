# Argo CD Bootstrap

This directory contains Argo CD `AppProject` and `Application` manifests for managing deployments of `my-app`.

## Prerequisites

- `kubectl` configured against your target cluster
- Cluster admin permissions

## Bootstrap Steps

### 1. Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for pods to become ready:

```bash
kubectl -n argocd wait --for=condition=available deployment --all --timeout=120s
```

### 2. Apply project and applications

```bash
kubectl apply -f argocd/
```

This creates:
- `AppProject/my-app` — scopes allowed sources and destinations (production, staging, preview-*)
- `Application/my-app-production` — tracks `k8s/overlays/production`, auto-syncs with prune + selfHeal
- `Application/my-app-staging` — tracks `k8s/overlays/staging`, auto-syncs with prune + selfHeal

### 3. Access the UI (optional)

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080  (admin / <password from above>)
```

## Application layout

| Application          | Source path              | Destination namespace |
|----------------------|--------------------------|-----------------------|
| my-app-production    | k8s/overlays/production  | production            |
| my-app-staging       | k8s/overlays/staging     | staging               |
| my-app-preview-\<PR> | k8s/overlays/staging *   | preview-pr-\<N>       |

\* PR preview namespaces are created by `scripts/pr-preview-up.sh`, not by an Argo CD Application.
  See `docs/pr-preview.md` for details.

## Notes

- The production overlay uses an Argo `Rollout` (canary strategy) instead of a plain `Deployment`.
  Argo CD treats `Rollout` resources as healthy once the desired replicas are available.
- `ignoreDifferences` for `Rollout.spec.replicas` prevents Argo CD from reverting HPA-driven
  replica counts during a sync.
