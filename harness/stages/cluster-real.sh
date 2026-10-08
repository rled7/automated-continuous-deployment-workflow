#!/usr/bin/env bash
# Deploy the staging overlay to a real kind cluster the way the Jenkinsfile
# deploys it (migrations via `kubectl run`, apply, rollout status), with a
# throwaway Postgres/Redis, then run the smoke tests through the Service.
# Unlike the pod stage, NetworkPolicies, Pod Security, Services and probes are
# enforced by Kubernetes itself. Needs a host where kind works (your machine,
# GitHub Actions). KEEP=1 leaves the cluster running.
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"
source "$HARNESS_DIR/lib/kind.sh"

CLUSTER=harness-verify
NS=staging

need_tools kind kubectl kustomize || exit 1
ensure_docker || exit 1
docker image inspect "$DEPLOY_IMAGE" >/dev/null 2>&1 || { log "image $DEPLOY_IMAGE missing; run the image stage first"; exit 1; }

pf_pid=""
teardown() {
  [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null
  kubectl -n "$NS" logs deploy/my-app --all-containers --tail=200 > "$RESULTS_DIR/logs/cluster-real-app.log" 2>&1
  if [ "$STEP_FAILURES" -gt 0 ]; then
    dump_cluster_state "$NS"
    tail -n 40 "$RESULTS_DIR/logs/cluster-real-app.log" >&2
  fi
  [ "${KEEP:-0}" = 1 ] && { log "KEEP=1: kind cluster $CLUSTER left running (KUBECONFIG=$KUBECONFIG)"; return; }
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
}
trap teardown EXIT

kind_cluster_up "$CLUSTER" || finish_stage
rendered=$(render_overlay "$NS") || exit 1
namespace_up "$rendered" || finish_stage
deps_up "$NS" "$rendered" || finish_stage

# The migration pod reads the overlay's ConfigMap, and its NetworkPolicy must
# be in place for it to reach Postgres: apply those first, as on any deploy
# after the first.
apply_kinds "$rendered" ConfigMap NetworkPolicy >/dev/null
step "migrations (runMigrations() from the Jenkinsfile)" jenkins_run_migrations "$NS"
if [ $? -ne 0 ]; then
  log "falling back to running migrations from app/ source through a port-forward"
  kubectl -n "$NS" delete pod my-app-migrate-verify --ignore-not-found >/dev/null 2>&1
  [ -d "$REPO_ROOT/app/node_modules" ] || (cd "$REPO_ROOT/app" && npm ci --no-audit --no-fund >/dev/null)
  kubectl -n "$NS" port-forward svc/app-db 15432:5432 >/dev/null 2>&1 & db_pf=$!
  sleep 3
  (cd "$REPO_ROOT/app" && DB_HOST=127.0.0.1 DB_PORT=15432 DB_PASSWORD=verify-only-password \
    node node_modules/.bin/knex migrate:latest --knexfile=knexfile.js) >&2
  kill $db_pf 2>/dev/null
fi

# deployToKubernetes(): apply the overlay with the image set, then wait.
step "apply staging overlay" kubectl apply -f "$rendered" || finish_stage
step "rollout status deployment/my-app" kubectl -n "$NS" rollout status deployment/my-app --timeout=300s
kubectl -n "$NS" get pods -o wide >&2

# tests/ deps installed the way runSmokeTests() does it.
step "smoke test deps (npm ci, as Jenkins)" bash -c 'cd "$1/tests" && npm ci --no-audit --no-fund' _ "$REPO_ROOT"
smoke_through_service "$NS" 13000

finish_stage
