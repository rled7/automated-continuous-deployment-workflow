# Production Deployment

The repo runs end-to-end on a local kind cluster out of the box. Going to a real cloud production environment requires five concrete substitutions. This doc walks through each one with the exact commands.

> Run `./scripts/production-checklist.sh` before going live to verify items 1–3 are done.

## 1. Real domain + Let's Encrypt prod issuer

Replace the `nip.io` placeholders + `selfsigned-issuer` with a real domain + the `letsencrypt-prod` ClusterIssuer (already defined in `argocd/bootstrap/issuers/letsencrypt-prod.yaml`).

```bash
DOMAIN=app.example.com               # ← your real domain
STAGING_DOMAIN=staging.app.example.com

# Production overlay
sed -i "s|app.127.0.0.1.nip.io|$DOMAIN|g"      k8s/overlays/production/ingress-patch.yaml
sed -i 's|selfsigned-issuer|letsencrypt-prod|' k8s/overlays/production/ingress-patch.yaml

# Staging overlay
sed -i "s|staging.app.127.0.0.1.nip.io|$STAGING_DOMAIN|g" k8s/overlays/staging/ingress-patch.yaml
sed -i 's|selfsigned-issuer|letsencrypt-staging|'         k8s/overlays/staging/ingress-patch.yaml

git add k8s/overlays && git commit -m "infra: production domain + Let's Encrypt issuers"
```

Then point your DNS A/AAAA records at the cluster's ingress LoadBalancer IP (`kubectl get svc -n ingress-nginx ingress-nginx-controller`).

cert-manager will auto-issue certs on first request to the new hostnames.

## 2. Real container registry + signed agent image

The Jenkins agent image is referenced as `ghcr.io/YOUR_ORG/jenkins-cicd-agent:latest` in `docker/jenkins/jenkins.yaml`. Build, sign, and push it to your real registry, then update the reference.

```bash
REG=ghcr.io/your-org                  # ← your registry
TAG=20.18.1-$(git rev-parse --short HEAD)

# Build (multi-arch; agent runs on whatever Jenkins controller arch you have)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t $REG/jenkins-cicd-agent:$TAG \
  -f docker/jenkins-agent/Dockerfile docker/jenkins-agent --push

# Sign with cosign keyless (uses your OIDC; gh auth login first)
COSIGN_EXPERIMENTAL=1 cosign sign --yes $REG/jenkins-cicd-agent:$TAG

# Update JCasC reference
sed -i "s|ghcr.io/YOUR_ORG/jenkins-cicd-agent:latest|$REG/jenkins-cicd-agent:$TAG|" \
  docker/jenkins/jenkins.yaml

git add docker/jenkins/jenkins.yaml && git commit -m "ci: pin jenkins-cicd-agent to $TAG"
```

Same flow for the app image — but the Jenkinsfile already does that automatically on every build.

## 3. Replace `REPLACE_ME` placeholders via SealedSecret

Three places use literal `REPLACE_ME`:
- `argocd/bootstrap/apps/kube-prometheus-stack.yaml` — Alertmanager Slack webhook + PagerDuty routing key + SMTP credentials
- `argocd/bootstrap/apps/dex.yaml` — `staticClients[0].secret`
- `argocd/bootstrap/apps/oauth2-proxy.yaml` — `clientSecret` + `cookieSecret`

These need to come from sealed secrets, not chart values. Create the sealed secrets:

```bash
# Generate cookie secret (32 bytes base64)
COOKIE_SECRET=$(openssl rand -base64 32)

# Pick a long random value for the Dex/oauth2-proxy shared secret
OAUTH_SECRET=$(openssl rand -hex 32)

./scripts/seal-secret.sh auth oauth2-proxy-secrets \
  client-id=oauth2-proxy \
  client-secret=$OAUTH_SECRET \
  cookie-secret=$COOKIE_SECRET \
  | kubectl apply -f -

./scripts/seal-secret.sh auth dex-secrets \
  oauth2-proxy-client-secret=$OAUTH_SECRET \
  | kubectl apply -f -

./scripts/seal-secret.sh monitoring alertmanager-secrets \
  slack-webhook-url=https://hooks.slack.com/services/...           \
  pagerduty-routing-key=R01XXXXXXXX                                \
  smtp-username=alerts@example.com                                 \
  smtp-password=...                                                \
  | kubectl apply -f -
```

Then update the three Application manifests to load values from `envFrom` references to those Secrets instead of the literal `REPLACE_ME` strings. (The chart `valuesObject` blocks need to use `existingSecret` references — check each chart's docs for the exact key.)

The placeholders are intentional; without them Helm rendering would silently substitute empty strings and the auth/alerting paths would fail in opaque ways.

## 4. Run branch protection setup

```bash
gh auth login                            # if you haven't already
./scripts/setup-branch-protection.sh     # auto-detects the repo via gh repo view
```

This sets:
- `main`: required reviewer + linear history + required status checks (`Lint + Unit Tests`, `continuous-integration/jenkins/branch`)
- `develop`: status checks required, direct pushes allowed

See `docs/branch-protection.md` for emergency hotfix bypass procedure.

## 5. Promote `verify-image-signatures` Kyverno policy Audit → Enforce

After **at least 7 days of running signed image deploys with no policy violations**, promote:

```bash
# Verify zero FAIL results during soak
kubectl get policyreports -A -o json \
  | jq '.items[] | .results[] | select(.policy=="verify-image-signatures") | .result' \
  | sort | uniq -c

# Should show only `pass` (or `skip`). If any `fail` shows up — investigate first.

# Edit the policy
sed -i 's|validationFailureAction: Audit|validationFailureAction: Enforce|' \
  policies/kyverno/verify-image-signatures.yaml

git add policies/kyverno/verify-image-signatures.yaml \
  && git commit -m "sec: promote verify-image-signatures to Enforce"
```

After this, any image not signed with the configured cosign identity will be **rejected at admission** — no deploy.

## Putting it all together

Order matters:
1. **Domain + DNS first** — without DNS, cert-manager can't issue prod certs.
2. **Registry + agent image second** — without the agent, nothing builds.
3. **Sealed secrets third** — applications fail closed on missing secrets, not open.
4. **Branch protection fourth** — gating that catches mistakes from the moment you turn it on.
5. **Policy promotion last** — only after the soak period.

All five are in `scripts/production-checklist.sh` (where automatable).

## Other production swap recommendations (not strictly required)

| Component | kind default | Production swap |
|---|---|---|
| Object storage for Velero | MinIO in-cluster (`argocd/bootstrap/apps/minio.yaml`) | S3 / GCS / Azure Blob — disable the MinIO Application, point Velero at the cloud bucket |
| Database | docker-compose `app-db` (not real prod) | Managed RDS / Cloud SQL / MemoryStore + connection from `DB_HOST` SealedSecret |
| Tracing backend | Tempo single-binary local storage | `tempo-distributed` chart with S3/GCS storage backend |
| Secrets backend | Sealed Secrets | (optional) External Secrets Operator + Vault / AWS SM / GCP SM if you need cross-cluster sharing |
| Image registry | `localhost:5000` | GHCR / ECR / GAR / Harbor |
| Cluster | kind | EKS / GKE / AKS / DigitalOcean / Linode |

Each is a one-line annotation/value change in the corresponding manifest. The pipeline doesn't care which you pick.
