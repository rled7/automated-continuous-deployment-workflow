#!/usr/bin/env bash
# The production path of the Jenkinsfile, on a real kind cluster running the
# Argo Rollouts controller:
#
#   1. a cluster deployed before the overlay fix, still running the stray base
#      Deployment next to the Rollout;
#   2. deployToKubernetes('production'): migrations, apply, wait for the
#      Rollout (scripts/wait-for-rollout.sh), remove the stray Deployment,
#      smoke tests through the Service;
#   3. a second release whose canary fails, which wait-for-rollout.sh must
#      report, then rollback() and a wait for the Rollout to be healthy again
#      on the previous image.
#
# The canary fails because the harness runs no Prometheus, so the
# success-rate analysis errors and Argo aborts the rollout. That exercises the
# failure → rollback path, not the analysis query itself.
#
# Needs a host where kind works (your machine, GitHub Actions). Takes ~5 min:
# the canary pauses 2 min before its analysis. KEEP=1 leaves the cluster up.
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"
source "$HARNESS_DIR/lib/kind.sh"

CLUSTER=harness-prod
NS=production
ARGO_ROLLOUTS_VERSION=1.7.2
WAIT_FOR_ROLLOUT="$REPO_ROOT/scripts/wait-for-rollout.sh"

need_tools kind kubectl kustomize || exit 1
ensure_docker || exit 1
docker image inspect "$DEPLOY_IMAGE" >/dev/null 2>&1 || { log "image $DEPLOY_IMAGE missing; run the image stage first"; exit 1; }

pf_pid=""
teardown() {
  [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null
  if [ "$STEP_FAILURES" -gt 0 ]; then
    dump_cluster_state "$NS"
    kubectl -n "$NS" get analysisruns -o wide >&2 2>/dev/null
    kubectl -n "$NS" logs -l app=my-app --all-containers --tail=30 --prefix >&2 2>/dev/null
  fi
  [ "${KEEP:-0}" = 1 ] && { log "KEEP=1: kind cluster $CLUSTER left running (KUBECONFIG=$KUBECONFIG)"; return; }
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
}
trap teardown EXIT

rollout_image() { kubectl -n "$NS" get rollout/my-app -o jsonpath='{.spec.template.spec.containers[0].image}'; }

kind_cluster_up "$CLUSTER" || finish_stage

install_argo_rollouts() {
  kubectl create namespace argo-rollouts >/dev/null 2>&1
  kubectl apply -n argo-rollouts --server-side -f \
    "https://github.com/argoproj/argo-rollouts/releases/download/v${ARGO_ROLLOUTS_VERSION}/install.yaml" >/dev/null &&
    kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s
}
step "install Argo Rollouts controller v$ARGO_ROLLOUTS_VERSION" install_argo_rollouts || finish_stage

rendered=$(render_overlay "$NS") || exit 1
namespace_up "$rendered" || finish_stage
deps_up "$NS" "$rendered" || finish_stage

# 1. What production looks like before this fix: the base Deployment, which
#    the overlay failed to delete, running next to the Rollout.
stray_deployment() {
  local staging
  staging=$(render_overlay staging staging-for-stray-deployment) || return 1
  python3 - "$staging" <<'PY' | kubectl apply -f -
import sys, yaml
d = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Deployment")
d["metadata"]["namespace"] = "production"
d["spec"]["replicas"] = 1
print(yaml.safe_dump(d))
PY
}
# Its ServiceAccount comes from the overlay, which a pre-fix cluster already has.
apply_kinds "$rendered" ServiceAccount >/dev/null
step "pre-fix state: stray Deployment running" stray_deployment

# 2. deployToKubernetes('production', image).
apply_kinds "$rendered" ConfigMap NetworkPolicy >/dev/null
step "migrations (runMigrations() from the Jenkinsfile)" jenkins_run_migrations "$NS"
step "apply production overlay" kubectl apply -f "$rendered" || finish_stage
step "wait-for-rollout.sh: first release healthy" "$WAIT_FOR_ROLLOUT" "$NS" my-app 600 || finish_stage
step "stray Deployment removed" kubectl delete deployment/my-app --namespace="$NS" --ignore-not-found
no_deployment_left() { [ -z "$(kubectl -n "$NS" get deploy -l app=my-app -o name)" ]; }
step "only the Rollout serves my-app" no_deployment_left
kubectl -n "$NS" get rollout,pods -o wide >&2
smoke_through_service "$NS" 13001 "first release"

# 3. A release whose canary fails, then rollback() from the Jenkinsfile.
previous_image=$(rollout_image)   # what the pipeline saves as PREVIOUS_IMAGE
canary_image="${DEPLOY_IMAGE}-canary"
docker tag "$DEPLOY_IMAGE" "$canary_image"
step "load canary image" kind load docker-image "$canary_image" --name "$CLUSTER" || finish_stage
canary_rendered=$(DEPLOY_IMAGE=$canary_image render_overlay "$NS" production-canary) || exit 1
step "apply canary release" kubectl apply -f "$canary_rendered" || finish_stage
# The pipeline must see this as a failure (so post { failure } rolls back),
# and it must be Argo aborting the canary, not a timeout.
failed_canary_detected() {
  local phase
  if "$WAIT_FOR_ROLLOUT" "$NS" my-app 600; then log "wait-for-rollout.sh passed a failing canary"; return 1; fi
  phase=$(kubectl -n "$NS" get rollout/my-app -o jsonpath='{.status.phase}')
  log "rollout phase: $phase"
  [ "$phase" = Degraded ]
}
step "wait-for-rollout.sh reports the failed canary" failed_canary_detected

rollback() {
  kubectl patch rollout/my-app --namespace="$NS" --type=json -p "[
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"$previous_image\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/metadata/labels/version\", \"value\": \"${previous_image##*:}\"}
  ]"
}
step "rollback() from the Jenkinsfile" rollback
step "wait-for-rollout.sh: healthy after rollback" "$WAIT_FOR_ROLLOUT" "$NS" my-app 300
on_previous_image() { local got; got=$(rollout_image); log "rollout image: $got"; [ "$got" = "$previous_image" ]; }
step "running the previous image again" on_previous_image
smoke_through_service "$NS" 13002 "after rollback"

finish_stage
