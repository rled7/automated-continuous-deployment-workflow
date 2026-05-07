#!/usr/bin/env bash
# pr-preview-up.sh — spin up a PR preview environment
#
# Usage: ./scripts/pr-preview-up.sh <PR_NUMBER>
#
# Creates namespace preview-pr-<PR_NUMBER> and deploys the staging overlay
# into it (with the namespace rewritten). Requires kustomize and kubectl on
# PATH and a working kubeconfig.

set -euo pipefail

PR_NUMBER="${1:?Usage: $0 <PR_NUMBER>}"
PREVIEW_NS="preview-pr-${PR_NUMBER}"
OVERLAY_PATH="k8s/overlays/staging"

echo "[pr-preview-up] PR_NUMBER=${PR_NUMBER}  namespace=${PREVIEW_NS}"

# 1. Create namespace if it doesn't already exist
kubectl get namespace "${PREVIEW_NS}" >/dev/null 2>&1 || \
  kubectl create namespace "${PREVIEW_NS}"

# 2. Label the namespace so the AppProject's preview-* destination matches
kubectl label namespace "${PREVIEW_NS}" \
  app.kubernetes.io/managed-by=pr-preview \
  pr-number="${PR_NUMBER}" \
  --overwrite

# 3. Build the staging overlay and rewrite the namespace, then apply
kustomize build "${OVERLAY_PATH}" \
  | sed "s/namespace: staging/namespace: ${PREVIEW_NS}/g" \
  | kubectl apply -n "${PREVIEW_NS}" -f -

echo "[pr-preview-up] Done. Preview environment available in namespace ${PREVIEW_NS}."
echo "[pr-preview-up] To watch rollout: kubectl rollout status deploy/my-app -n ${PREVIEW_NS}"
