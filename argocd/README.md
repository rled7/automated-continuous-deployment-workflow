# Argo CD Bootstrap

This directory contains Argo CD `AppProject` and `Application` manifests for `my-app`.

## Who deploys what

- **Jenkins deploys the app.** `deployToKubernetes()` in the Jenkinsfile runs the
  migrations, sets the image with `kustomize edit set image`, adds a `version`
  label (the image tag; the Kyverno `require-labels` policy requires it), runs
  `kubectl apply -k k8s/overlays/<env>`, waits for the Rollout/Deployment and
  rolls back on failure. None of that is committed: git keeps `my-app:latest`
  and no `version` label.
- **Argo CD manages the platform** (`argocd/bootstrap/`: ingress-nginx,
  cert-manager, Argo Rollouts, kube-prometheus-stack, metrics-server, Kyverno
  and its policies, ...), with automated sync.
- The `my-app-production` / `my-app-staging` Applications here are for
  **visibility only**: Argo CD shows the app's health and its diff against git,
  but they do **not** auto-sync. With auto-sync and selfHeal, Argo CD would put
  `my-app:latest` without a `version` label back after every Jenkins deploy or
  rollback, and Kyverno would reject the pods. `ignoreDifferences` hides the
  fields Jenkins sets (container image, `version` label, HPA-driven replicas),
  and `RespectIgnoreDifferences=true` keeps their live values if someone syncs
  manually, e.g. to roll out a ConfigMap change between releases.

## Prerequisites

- `kubectl` configured against your target cluster
- Cluster admin permissions

## Bootstrap Steps

### 1. Install Argo CD

```bash
kubectl create namespace argocd
# Server-side apply (the ApplicationSet CRD is too big for client-side apply),
# pinned to the version scripts/setup.sh installs.
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
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
- `Application/my-app-production` — tracks `k8s/overlays/production`, manual sync only
- `Application/my-app-staging` — tracks `k8s/overlays/staging`, manual sync only

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
- `ignoreDifferences` covers `spec.replicas` (HPA-driven), the pod template's container image
  and the `version` label, which Jenkins sets at deploy time, so they are not reported as drift.
