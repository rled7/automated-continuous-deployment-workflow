#!/usr/bin/env bash
# pr-preview-up.sh — deploy a pull request's build as a preview environment
#
# Usage: ./scripts/pr-preview-up.sh <PR_NUMBER> <IMAGE> <HOST>
#   e.g. ./scripts/pr-preview-up.sh 42 registry.example.com/my-app:17-abc1234 pr-42.preview.example.com
#
# Deploys the staging overlay into namespace preview-pr-<PR_NUMBER> with:
#   - IMAGE, the image this PR's build pushed;
#   - the Ingress host HOST (and its own TLS secret);
#   - in-memory stores instead of Postgres and Redis (DB_FAKE / REDIS_FAKE,
#     NODE_ENV=preview): a preview has no database of its own, and its data
#     lives only as long as the pod;
#   - the registry pull secret copied from staging, when staging has one.
# Then waits for the rollout. Requires kustomize and kubectl on PATH and a
# kubeconfig allowed to create namespaces. Run from anywhere in the repo.

set -euo pipefail

PR_NUMBER="${1:?Usage: $0 <PR_NUMBER> <IMAGE> <HOST>}"
IMAGE="${2:?Usage: $0 <PR_NUMBER> <IMAGE> <HOST>}"
HOST="${3:?Usage: $0 <PR_NUMBER> <IMAGE> <HOST>}"
[[ $PR_NUMBER =~ ^[0-9]+$ ]] || { echo "PR_NUMBER must be a number, got '$PR_NUMBER'" >&2; exit 1; }
PREVIEW_NS="preview-pr-${PR_NUMBER}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[pr-preview-up] PR ${PR_NUMBER}: ${IMAGE} → namespace ${PREVIEW_NS}, https://${HOST}"

# 1. The namespace, labelled so the AppProject's preview-* destination matches.
kubectl create namespace "${PREVIEW_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${PREVIEW_NS}" \
  app.kubernetes.io/managed-by=pr-preview \
  pr-number="${PR_NUMBER}" \
  --overwrite

# 2. Secrets. The Deployment reads my-app-secrets (unused with the in-memory
#    store, but the pod cannot start without it); the pull secret comes from
#    staging, if staging pulls from a private registry.
kubectl -n "${PREVIEW_NS}" create secret generic my-app-secrets \
  --from-literal=db-host=unused --from-literal=db-password=unused \
  --dry-run=client -o yaml | kubectl apply -f -
if kubectl -n staging get secret registry-credentials >/dev/null 2>&1; then
  kubectl -n staging get secret registry-credentials -o json |
    jq --arg ns "${PREVIEW_NS}" '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: $ns}}' |
    kubectl apply -f -
fi

# 3. The staging overlay, adapted for this PR, through a temporary overlay
#    beside it (kustomize only accepts relative paths to a base).
work=$(mktemp -d "${REPO_ROOT}/k8s/overlays/.preview-${PR_NUMBER}.XXXXXX")
trap 'rm -rf "$work"' EXIT
cat > "$work/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${PREVIEW_NS}
resources:
  - ../staging
images:
  - name: my-app
    newName: ${IMAGE%:*}
    newTag: ${IMAGE##*:}
labels:
  - pairs:
      pr-number: "${PR_NUMBER}"
patches:
  - target: {kind: ConfigMap, name: my-app-config}
    patch: |
      - op: add
        path: /data/NODE_ENV
        value: preview
      - op: add
        path: /data/DB_FAKE
        value: "1"
      - op: add
        path: /data/REDIS_FAKE
        value: "1"
  - target: {kind: Ingress, name: my-app}
    patch: |
      - op: replace
        path: /spec/rules/0/host
        value: ${HOST}
      - op: replace
        path: /spec/tls/0/hosts/0
        value: ${HOST}
      - op: replace
        path: /spec/tls/0/secretName
        value: my-app-tls-${PREVIEW_NS}
  # The staging Deployment sets NODE_ENV on the container, which wins over the
  # ConfigMap; the app refuses the in-memory stores under NODE_ENV=staging.
  - target: {kind: Deployment, name: my-app}
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: my-app
      spec:
        template:
          metadata:
            labels:
              version: "${IMAGE##*:}"
          spec:
            containers:
              - name: my-app
                env:
                  - name: NODE_ENV
                    value: preview
EOF
kustomize build "$work" | kubectl apply -f -

# 4. Ready when the rollout is; if it is not, say why.
if ! kubectl -n "${PREVIEW_NS}" rollout status deployment/my-app --timeout=300s; then
  echo "[pr-preview-up] The preview did not become ready:" >&2
  kubectl -n "${PREVIEW_NS}" get pods -o wide >&2 || true
  kubectl -n "${PREVIEW_NS}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 25 >&2 || true
  kubectl -n "${PREVIEW_NS}" logs deployment/my-app --tail=40 >&2 2>&1 || true
  exit 1
fi

echo "[pr-preview-up] Preview for PR ${PR_NUMBER} is up: https://${HOST}"
