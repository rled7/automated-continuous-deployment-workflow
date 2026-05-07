# Local Cluster Setup (kind + Argo CD)

This guide spins up a local Kubernetes cluster with
[kind](https://kind.sigs.k8s.io/), bootstraps Argo CD, and installs all
platform components via the app-of-apps pattern.

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| Docker Desktop or Docker Engine | Container runtime for kind | https://docs.docker.com/get-docker/ |
| kind | Local Kubernetes via Docker | `brew install kind` / https://kind.sigs.k8s.io |
| kubectl | Kubernetes CLI | `brew install kubectl` |
| kubeseal | Sealed Secrets CLI | `brew install kubeseal` |
| helm | Verify chart values locally (optional) | `brew install helm` |

Verify:

```bash
docker version
kind version
kubectl version --client
kubeseal --version
```

## 1. Create the kind cluster

Save the following as `kind-config.yaml` (or use the inline copy below) and
create the cluster.  The `extraPortMappings` forward host ports 80 and 443 to
the ingress-nginx NodePort service so nip.io URLs work without any DNS changes.

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # Maps host:80  → ingress-nginx NodePort 30080
      - containerPort: 30080
        hostPort: 80
        protocol: TCP
      # Maps host:443 → ingress-nginx NodePort 30443
      - containerPort: 30443
        hostPort: 443
        protocol: TCP
```

```bash
kind create cluster --name cicd-demo --config kind-config.yaml
kubectl cluster-info --context kind-cicd-demo
```

## 2. Bootstrap Argo CD

```bash
# Create the argocd namespace and install Argo CD
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for argocd-server to be ready
kubectl rollout status -n argocd deployment/argocd-server --timeout=120s
```

Retrieve the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

## 3. Apply the platform AppProject and root Application

```bash
kubectl apply -f argocd/bootstrap/projects/platform.yaml
kubectl apply -f argocd/bootstrap/root.yaml
```

Argo CD will now discover every `Application` in `argocd/bootstrap/apps/` and
sync them in sync-wave order:

| Wave | Components |
|------|-----------|
| -10 | sealed-secrets, ingress-nginx, cert-manager, argo-rollouts |
| 0 | cert-manager-issuers, kube-prometheus-stack, loki-stack, otel-collector |

Watch progress:

```bash
kubectl get applications -n argocd --watch
```

## 4. Apply the my-app project and applications

Once all platform components are `Healthy / Synced`:

```bash
kubectl apply -f argocd/AppProject.yaml
kubectl apply -f argocd/Application-staging.yaml
kubectl apply -f argocd/Application-production.yaml
```

## 5. Seal and apply secrets

Before the app can start, seal the secrets for your cluster (see `docs/secrets.md`):

```bash
scripts/seal-secret.sh production my-app-secrets \
    db-host=localhost \
    db-password=devpassword \
  > k8s/secrets/my-app-secrets.yaml

scripts/seal-secret.sh staging my-app-secrets \
    db-host=localhost \
    db-password=devpassword \
  > k8s/secrets/my-app-secrets-staging.yaml

# Commit and push — Argo CD will apply them automatically
git add k8s/secrets/
git commit -m "chore: seal my-app-secrets for local kind cluster"
git push
```

## 6. Accessing the apps

### Argo CD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8081:443
# Open https://localhost:8081  (admin / <password from step 2>)
```

### my-app via nip.io

Once ingress-nginx is running and the app is deployed:

- Staging:    https://staging.app.127.0.0.1.nip.io
- Production: https://app.127.0.0.1.nip.io

These hostnames resolve to `127.0.0.1` via the nip.io wildcard DNS service, and
the kind `extraPortMappings` forward port 443 to the ingress controller's
NodePort.  You will see a certificate warning because the `selfsigned-issuer` is
used (expected for local dev).

### Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Open http://localhost:3000  (admin / changeme-bootstrap-only)
```

### Argo Rollouts dashboard

```bash
kubectl port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100
# Open http://localhost:3100
```

## 7. Tear down

```bash
kind delete cluster --name cicd-demo
```

This removes the cluster and all local volumes.  Sealed secret templates in
`k8s/secrets/` are still in git — re-seal against a new cluster before
re-applying (the ciphertext is cluster-specific; see `docs/secrets.md`).
