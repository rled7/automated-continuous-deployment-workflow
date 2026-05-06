#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# seal-secret.sh — Create a SealedSecret from key=value pairs
#
# Usage:
#   scripts/seal-secret.sh <namespace> <secret-name> <key=value> [<key=value>...]
#
# Example:
#   scripts/seal-secret.sh production my-app-secrets \
#       db-host=mydb.internal \
#       db-password=supersecret \
#     > k8s/secrets/my-app-secrets.yaml
#
# The script:
#   1. Builds a plain Kubernetes Secret in memory (never touches the cluster).
#   2. Pipes it through kubeseal, which fetches the controller's public key and
#      encrypts each value.
#   3. Prints the SealedSecret YAML to stdout so you can redirect it to a file.
#
# Prerequisites:
#   - kubectl configured against the target cluster
#   - kubeseal CLI installed (https://github.com/bitnami-labs/sealed-secrets)
#   - sealed-secrets controller running in kube-system
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 <namespace> <secret-name> <key=value> [<key=value>...]" >&2
    echo "Example: $0 production my-app-secrets db-host=mydb db-password=secret" >&2
    exit 1
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# ── Validate arguments ────────────────────────────────────────────────────────
[[ $# -lt 3 ]] && usage

NAMESPACE="$1"
SECRET_NAME="$2"
shift 2

# Remaining args are key=value pairs
KV_ARGS=("$@")

# ── Validate required tools ────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
    error "kubectl not found on PATH. Install kubectl and configure it against your cluster."
fi

if ! command -v kubeseal &>/dev/null; then
    error "kubeseal not found on PATH. Install kubeseal from:
  https://github.com/bitnami-labs/sealed-secrets/releases
  Or via Homebrew: brew install kubeseal"
fi

# ── Build from-literal flags ──────────────────────────────────────────────────
LITERAL_FLAGS=()
for kv in "${KV_ARGS[@]}"; do
    # Validate each argument is in key=value form
    [[ "$kv" == *"="* ]] || error "Argument '$kv' is not in key=value form."
    LITERAL_FLAGS+=("--from-literal=${kv}")
done

# ── Seal ──────────────────────────────────────────────────────────────────────
# Step 1: create a dry-run Secret YAML (nothing is applied to the cluster)
# Step 2: pipe through kubeseal to encrypt with the controller's public key
kubectl create secret generic "${SECRET_NAME}" \
    --namespace="${NAMESPACE}" \
    "${LITERAL_FLAGS[@]}" \
    --dry-run=client \
    -o yaml \
  | kubeseal \
      --format=yaml \
      --controller-namespace=kube-system \
      --controller-name=sealed-secrets-controller
