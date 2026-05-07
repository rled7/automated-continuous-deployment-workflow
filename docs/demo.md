# Demo Walkthrough

A 15-minute end-to-end tour of what this repo does. Useful for an interview demo or a "what did you build" review.

> Pre-reqs: Docker, kind, kubectl, kubeseal, helm, gh (optional), make.

## 1 — Boot the local cluster (~2 min)

```bash
make kind-up         # creates kind cluster with extraPortMappings 80/443
make bootstrap       # installs Argo CD + applies the platform root
kubectl get applications -n argocd -w
```

Watch the bootstrap Application sync 16+ child Applications: sealed-secrets, ingress-nginx, cert-manager (+ ClusterIssuers), kube-prometheus-stack, loki, tempo, otel-collector, promtail, kyverno, kyverno-policies, argo-rollouts, velero, minio, chaos-mesh, dex, oauth2-proxy, grafana-dashboards.

## 2 — Apply the my-app overlays (~30 s)

```bash
kubectl apply -f argocd/AppProject.yaml
kubectl apply -f argocd/Application-staging.yaml
kubectl apply -f argocd/Application-production.yaml
```

Argo CD reconciles the Kustomize overlays. Production uses an Argo Rollout with a canary strategy; staging uses a plain Deployment.

## 3 — Seal real secrets (~1 min)

```bash
make seal-secret NS=production NAME=my-app-secrets \
  KEYS="db-host=app-db.production.svc.cluster.local db-password=demo-only" \
  | kubectl apply -f -

make seal-secret NS=staging NAME=my-app-secrets \
  KEYS="db-host=app-db.staging.svc.cluster.local db-password=demo-only" \
  | kubectl apply -f -
```

The placeholder SealedSecret templates in `k8s/secrets/` show the shape; never apply them with placeholder ciphertext.

## 4 — Hit the app (~30 s)

```bash
open http://app.127.0.0.1.nip.io           # production
open http://staging.app.127.0.0.1.nip.io   # staging
```

Both are gated by oauth2-proxy → Dex. Log in with the demo static user (see `docs/edge-auth.md` for the bcrypt seed).

```bash
curl http://app.127.0.0.1.nip.io/api/items
curl -X POST -H 'Content-Type: application/json' \
  -d '{"name":"demo-from-walkthrough"}' \
  http://app.127.0.0.1.nip.io/api/items
```

## 5 — See what's happening (~3 min)

```bash
# Argo CD UI
kubectl port-forward -n argocd svc/argocd-server 8081:443 &
open https://localhost:8081

# Grafana — auto-imported dashboards: app-overview, slo, dora, pipeline
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3001:80 &
open http://localhost:3001
# user: admin  /  pass: changeme-bootstrap-only

# Argo Rollouts dashboard
kubectl argo rollouts dashboard
```

In Grafana → Dashboards:
- **app-overview** — RED metrics (rate, errors, duration)
- **slo** — burn-down for 99.9% availability target
- **dora** — deployment frequency / lead time / change failure rate / MTTR
- **pipeline** — Jenkins build durations + success rate

## 6 — Trigger the pipeline (~5 min)

Push a commit on a feature branch:

```bash
git checkout -b feature/walkthrough-demo
echo "// demo $(date +%s)" >> app/src/server.js
git commit -am "feat(app): walkthrough demo commit"
git push origin feature/walkthrough-demo
gh pr create --base develop --title "feat(app): walkthrough demo" --body "demo"
```

Two CI systems fire in parallel:
- **GitHub Actions** (`Lint + Unit Tests`) — finishes in <1 min
- **Jenkins** (full pipeline) — runs SonarQube + OWASP + ESLint + Gitleaks → kubeconform → unit + integration → buildx multi-arch + Trivy + syft + cosign + grype → PR preview deploy in `preview-pr-N` namespace

Open the PR preview:

```bash
open http://app.127.0.0.1.nip.io       # the namespace is preview-pr-N
```

Merge to develop → Jenkins deploys to staging → runs k6 + Playwright. Merge to main → manual gate → Argo Rollouts canary 25 → analysis (Prometheus 5xx rate ≥ 0.99) → 50 → analysis → 100.

## 7 — Show off the resilience story (~2 min)

Apply a chaos experiment:

```bash
kubectl apply -f chaos/pod-failure.yaml      # kills 50% of staging pods for 60s
```

Watch Argo Rollouts/Deployment recover. Check Grafana to see the latency blip and the alerting tree react.

Show a Velero backup:

```bash
kubectl get backups -n velero
velero backup describe daily-staging-... --details
```

## 8 — Walk through the Kyverno policies (~1 min)

```bash
kubectl get clusterpolicies
# 9 policies: 7 Enforce, 2 Audit
kubectl get policyreports -A | head -20
```

Try to violate one — `kubectl run bad --image=nginx:latest -n production` will be rejected by `disallow-latest-tag`.

## 9 — Wrap

Optionally tear down:

```bash
make kind-down
```

## What this demonstrates end-to-end

- GitOps (Argo CD reconciling 16+ Applications + the my-app overlays)
- Progressive delivery (Argo Rollouts canary with Prometheus AnalysisTemplate)
- Observability (metrics + logs + traces + DORA)
- Supply chain (multi-arch + SBOM + cosign + SLSA + grype)
- Cluster security (Kyverno + NetworkPolicies + PSS-restricted)
- Resilience (Velero backups + Chaos Mesh experiments)
- Edge auth (Dex + oauth2-proxy)
- Developer experience (pre-commit + parallel GH Actions / Jenkins)
- Real DB integration (Postgres + Redis + knex migrations)

15 minutes covers the happy path. See `docs/runbook.md` for "things break" + `docs/dr-runbook.md` for "things really break."
