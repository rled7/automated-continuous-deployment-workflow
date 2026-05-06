#!/usr/bin/env bash
# pr-preview-down.sh — tear down a PR preview environment
#
# Usage: ./scripts/pr-preview-down.sh <PR_NUMBER>
#
# Deletes namespace preview-pr-<PR_NUMBER> and all resources inside it.
# Requires kubectl on PATH and a working kubeconfig.

set -euo pipefail

PR_NUMBER="${1:?Usage: $0 <PR_NUMBER>}"
PREVIEW_NS="preview-pr-${PR_NUMBER}"

echo "[pr-preview-down] Deleting namespace ${PREVIEW_NS} ..."

if kubectl get namespace "${PREVIEW_NS}" >/dev/null 2>&1; then
  kubectl delete namespace "${PREVIEW_NS}"
  echo "[pr-preview-down] Namespace ${PREVIEW_NS} deleted."
else
  echo "[pr-preview-down] Namespace ${PREVIEW_NS} does not exist — nothing to do."
fi
