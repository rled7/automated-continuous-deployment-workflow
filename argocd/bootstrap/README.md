# Argo CD App-of-Apps Bootstrap

This directory contains the **platform bootstrap layer**: the `AppProject` and
root `Application` that Argo CD uses to install and manage all platform
components (ingress-nginx, cert-manager, sealed-secrets, monitoring, etc.).

## Directory layout

```
argocd/bootstrap/
├── projects/
│   └── platform.yaml          # AppProject that scopes all platform apps
├── root.yaml                  # Root Application — Argo scans bootstrap/apps/
├── apps/                      # One Application per platform component
│   ├── sealed-secrets.yaml
│   ├── ingress-nginx.yaml
│   ├── cert-manager.yaml
│   ├── cert-manager-issuers.yaml
│   ├── argo-rollouts.yaml
│   ├── kube-prometheus-stack.yaml
│   ├── loki-stack.yaml
│   └── otel-collector.yaml
└── issuers/                   # Raw ClusterIssuer manifests (no Helm)
    ├── selfsigned-issuer.yaml
    ├── letsencrypt-staging.yaml
    └── letsencrypt-prod.yaml
```

## Prerequisites

- A running Kubernetes cluster (see `docs/cluster-setup.md` for kind setup)
- `kubectl` configured against that cluster (`kubectl cluster-info`)
- Cluster admin permissions
- `kubeseal` CLI (for sealing secrets after bootstrap)
- `helm` (optional — useful for checking chart values locally)

## Bootstrap steps

### 1. Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 2. Wait for Argo CD to be ready

```bash
kubectl rollout status -n argocd deployment/argocd-server --timeout=120s
```

Retrieve the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

### 3. Apply the platform AppProject and root Application

```bash
kubectl apply -f argocd/bootstrap/projects/platform.yaml
kubectl apply -f argocd/bootstrap/root.yaml
```

Argo CD will discover every manifest in `argocd/bootstrap/apps/` and sync them.
Components install in sync-wave order (wave -10 first, then wave 0).

### 4. Watch sync progress

```bash
kubectl get applications -n argocd
# or with live updates:
kubectl get applications -n argocd --watch
```

All applications should reach `Healthy / Synced` within a few minutes.
`cert-manager-issuers` (wave 0) may need an extra reconcile cycle after
`cert-manager` (wave -10) finishes installing its CRDs.

### 5. Apply the my-app project and applications

Once all platform components are healthy:

```bash
kubectl apply -f argocd/AppProject.yaml
kubectl apply -f argocd/Application-staging.yaml
kubectl apply -f argocd/Application-production.yaml
```

### 6. Seal and apply app secrets

```bash
scripts/seal-secret.sh production my-app-secrets \
    db-host=<value> db-password=<value> \
  > k8s/secrets/my-app-secrets.yaml
git add k8s/secrets/my-app-secrets.yaml
git commit -m "chore: seal production secrets for cluster"
git push
```

See `docs/secrets.md` for full details.

### 7. Access UIs

```bash
# Argo CD
kubectl port-forward svc/argocd-server -n argocd 8081:443
# https://localhost:8081  (admin / <password>)

# Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# http://localhost:3000  (admin / changeme-bootstrap-only)

# Argo Rollouts dashboard
kubectl port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100
# http://localhost:3100
```

## Sync waves

| Wave | Components | Reason |
|------|-----------|--------|
| -10 | `sealed-secrets`, `ingress-nginx`, `cert-manager`, `argo-rollouts` | CRD controllers; must be ready before dependent resources |
| 0 | `cert-manager-issuers`, `kube-prometheus-stack`, `loki-stack`, `otel-collector` | Require CRDs from wave -10 |

## Notes

- `cert-manager-issuers` uses a `directory` source (not Helm) pointing at
  `argocd/bootstrap/issuers/`.  It contains three `ClusterIssuer` manifests:
  `selfsigned-issuer` (kind/local), `letsencrypt-staging`, and `letsencrypt-prod`.
  Only `selfsigned-issuer` is active by default; the others require a real DNS
  name and reachable port 80.
- For cloud deployments, update the `cert-manager.io/cluster-issuer` annotation
  in `k8s/overlays/*/ingress-patch.yaml` from `selfsigned-issuer` to
  `letsencrypt-staging` or `letsencrypt-prod`.
- OTel collector currently exports to the `logging` exporter (traces appear in
  collector logs).  Replace with an `otlp` exporter pointing at Grafana Tempo
  when Tempo is added to the stack.
