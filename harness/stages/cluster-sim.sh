#!/usr/bin/env bash
# Apply every overlay to a KWOK cluster: a real kube-apiserver, scheduler and
# controller-manager with simulated nodes. Pods are scheduled and reported
# Running without starting containers, so this checks that the API server
# accepts the manifests and that workloads, HPAs and PDBs wire up — not that
# the app runs (the pod and cluster-real stages do that).
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"

ARGO_ROLLOUTS_VERSION=1.7.2
CLUSTER=harness-verify

need_tools kubectl kustomize kwokctl kwok || exit 1

export KWOK_KUBE_VERSION=v1.31.0
teardown() {
  [ "${KEEP:-0}" = 1 ] && { log "KEEP=1: cluster $CLUSTER left running"; return; }
  kwokctl delete cluster --name "$CLUSTER" >/dev/null 2>&1
}
trap teardown EXIT

kwokctl delete cluster --name "$CLUSTER" >/dev/null 2>&1
step "create KWOK cluster" kwokctl create cluster --name "$CLUSTER" --runtime binary --wait 2m || finish_stage
export KUBECONFIG="$HOME/.kwok/clusters/$CLUSTER/kubeconfig.yaml"
step "add 3 simulated nodes" kwokctl scale node --name "$CLUSTER" --replicas 3

# CRDs the overlays use. Server-side apply: the Rollout CRD is too large for
# the client-side last-applied annotation.
step "install Argo Rollouts CRDs" kubectl apply --server-side -f \
  "https://github.com/argoproj/argo-rollouts/releases/download/v${ARGO_ROLLOUTS_VERSION}/install.yaml"

for dir in "$REPO_ROOT"/k8s/overlays/*/; do
  overlay=$(basename "$dir")
  rendered=$(render_overlay "$overlay") || { step "render $overlay" false; continue; }
  ns=$(python3 -c 'import sys,yaml; print(next(d["metadata"]["name"] for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"]=="Namespace"))' "$rendered")

  # Dry run can't validate namespaced objects in a namespace that doesn't exist yet.
  kubectl create namespace "$ns" >/dev/null 2>&1
  step "server-side dry run $overlay" kubectl apply --server-side --dry-run=server -f "$rendered" || continue
  step "apply $overlay" kubectl apply --server-side -f "$rendered" || continue
  # Secrets are SealedSecrets in real clusters; use the test stand-in.
  kubectl -n "$ns" apply -f "$HARNESS_DIR/fixtures/app-secret.yaml" >/dev/null

  # The API server's Pod Security admission (the namespaces enforce
  # "restricted") only sees pods, which KWOK never gets from CRDs like the
  # Rollout. Submit each workload's pod template, and the migration pod, as a
  # Pod in a server-side dry run so admission judges them as it would for real.
  pods="$RESULTS_DIR/rendered/$overlay-template-pods.yaml"
  python3 - "$rendered" > "$pods" <<'PY'
import sys, yaml
out = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d["kind"] in ("Deployment", "StatefulSet", "DaemonSet", "Rollout"):
        t = d["spec"]["template"]
        out.append({"apiVersion": "v1", "kind": "Pod",
                    "metadata": {"name": f'{d["kind"].lower()}-{d["metadata"]["name"]}-template',
                                 "namespace": d["metadata"]["namespace"],
                                 "labels": t["metadata"].get("labels", {})},
                    "spec": t["spec"]})
print(yaml.safe_dump_all(out, sort_keys=False))
PY
  step "$overlay workload pods pass Pod Security admission" kubectl apply --dry-run=server -f "$pods"
  migrate_pod_dry_run() { migrate_pod_yaml "$ns" "$DEPLOY_IMAGE" my-app-migrate-verify | kubectl apply --dry-run=server -f -; }
  step "$overlay migration pod passes Pod Security admission" migrate_pod_dry_run

  for d in $(kubectl -n "$ns" get deploy -o name); do
    step "$overlay $d rolled out" kubectl -n "$ns" rollout status "$d" --timeout=90s
  done
  hpa_target_exists() {
    local kind name
    for hpa in $(kubectl -n "$ns" get hpa -o name); do
      kind=$(kubectl -n "$ns" get "$hpa" -o jsonpath='{.spec.scaleTargetRef.kind}')
      name=$(kubectl -n "$ns" get "$hpa" -o jsonpath='{.spec.scaleTargetRef.name}')
      kubectl -n "$ns" get "$kind/$name" >/dev/null || { log "$hpa targets missing $kind/$name"; return 1; }
    done
  }
  step "$overlay HPA targets exist" hpa_target_exists
  kubectl -n "$ns" get deploy,rollout,pods,hpa,pdb >&2
done

finish_stage
