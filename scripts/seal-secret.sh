#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# seal-secret.sh — Create a SealedSecret from key=value pairs
#
# Usage:
#   scripts/seal-secret.sh <namespace> <secret-name> <key=value> [<key=value>...]
#   scripts/seal-secret.sh <namespace> <secret-name> < values.env
#
# Example:
#   scripts/seal-secret.sh production my-app-secrets \
#       db-host=mydb.internal \
#       db-password=supersecret \
#     > k8s/secrets/my-app-secrets.yaml
#
# Values given as arguments are visible to other users of the machine (ps)
# and kept in shell history. To avoid that, give no pairs and pipe key=value
# lines on stdin instead, one per line (a value cannot span lines; lines
# starting with # are skipped):
#   printf 'db-host=%s\ndb-password=%s\n' "$DB_HOST" "$DB_PASSWORD" \
#     | scripts/seal-secret.sh production my-app-secrets \
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
    echo "       $0 <namespace> <secret-name> < file-of-key=value-lines" >&2
    echo "Example: $0 production my-app-secrets db-host=mydb db-password=secret" >&2
    exit 1
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# ── Validate arguments ────────────────────────────────────────────────────────
[[ $# -lt 2 ]] && usage
# No pairs and nothing piped in: show the usage rather than wait on the terminal.
[[ $# -eq 2 && -t 0 ]] && usage

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

# ── Build the data flags ──────────────────────────────────────────────────────
# Pairs from the arguments become --from-literal flags; with none, kubectl
# reads key=value lines from this script's stdin.
DATA_FLAGS=()
STDIN_DATA=""
for kv in ${KV_ARGS[@]+"${KV_ARGS[@]}"}; do
    # Validate each argument is in key=value form
    [[ "$kv" == *"="* ]] || error "Argument '$kv' is not in key=value form."
    DATA_FLAGS+=("--from-literal=${kv}")
done
if [[ ${#DATA_FLAGS[@]} -eq 0 ]]; then
    STDIN_DATA="$(cat)"
    grep -qv -e '^[[:space:]]*$' -e '^[[:space:]]*#' <<<"$STDIN_DATA" \
        || error "No key=value pairs: give them as arguments or as lines on stdin."
    DATA_FLAGS=("--from-env-file=/dev/stdin")
fi

# ── Seal ──────────────────────────────────────────────────────────────────────
# Step 1: create a dry-run Secret YAML (nothing is applied to the cluster)
# Step 2: pipe through kubeseal to encrypt with the controller's public key
printf '%s\n' "$STDIN_DATA" \
  | kubectl create secret generic "${SECRET_NAME}" \
      --namespace="${NAMESPACE}" \
      "${DATA_FLAGS[@]}" \
      --dry-run=client \
      -o yaml \
  | kubeseal \
      --format=yaml \
      --controller-namespace=kube-system \
      --controller-name=sealed-secrets-controller
