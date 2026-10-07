#!/usr/bin/env bash
# Render every overlay, then validate schemas, cross-object sanity and the
# repo's Kyverno policies. No cluster needed.
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"

need_tools kustomize kubectl kubeconform kyverno || exit 1

# CRD schemas (Argo Rollouts, SealedSecrets, ...) come from the community catalog.
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

rendered=()
for dir in "$REPO_ROOT"/k8s/overlays/*/; do
  overlay=$(basename "$dir")
  out="$RESULTS_DIR/rendered/$overlay.yaml"
  step "render $overlay" render_overlay "$overlay" >/dev/null && rendered+=("$out")
done

for f in "${rendered[@]}"; do
  overlay=$(basename "$f" .yaml)
  step "schema $overlay" kubeconform -strict -summary -kubernetes-version 1.31.0 \
    -schema-location default -schema-location "$CRD_SCHEMAS" "$f"
done

step "sanity (cross-object)" python3 "$HARNESS_DIR/checks/manifest_sanity.py" "${rendered[@]}"

# Kyverno: the repo's own admission policies, evaluated offline.
policies=()
for p in "$REPO_ROOT"/policies/kyverno/*.yaml; do policies+=("$p"); done
for f in "${rendered[@]}"; do
  overlay=$(basename "$f" .yaml)
  # The migration pod runMigrations() starts in this namespace.
  migrate_pod_yaml "$overlay" "$DEPLOY_IMAGE" my-app-migrate-verify > "$RESULTS_DIR/rendered/$overlay-migrate-pod.yaml"
  step "kyverno $overlay migration pod" kyverno apply "${policies[@]}" \
    --resource "$RESULTS_DIR/rendered/$overlay-migrate-pod.yaml" --audit-warn=false
  step "kyverno $overlay" kyverno apply "${policies[@]}" --resource "$f" --audit-warn=false
done

finish_stage
