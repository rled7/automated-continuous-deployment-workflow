# shellcheck shell=bash
# Shared by the stages that deploy to a real kind cluster (cluster-real,
# cluster-prod). Source after common.sh and tools.sh.

KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-mirror.gcr.io/kindest/node:v1.31.0}"

# kind_cluster_up NAME — creates the cluster, points KUBECONFIG at it and
# loads $DEPLOY_IMAGE. Steps fail the stage on error.
kind_cluster_up() {
  local name=$1
  export KUBECONFIG="${KIND_KUBECONFIG:-$(mktemp)}"
  kind delete cluster --name "$name" >/dev/null 2>&1
  step "create kind cluster" kind create cluster --name "$name" --image "$KIND_NODE_IMAGE" --wait 180s || return 1
  step "load app image" kind load docker-image "$DEPLOY_IMAGE" --name "$name"
}

# apply_kinds RENDERED KIND... — applies only the documents of the given kinds.
apply_kinds() {
  local rendered=$1; shift
  python3 - "$rendered" "$@" <<'PY' | kubectl apply -f -
import sys, yaml
kinds = set(sys.argv[2:])
print(yaml.safe_dump_all([d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] in kinds]))
PY
}

# namespace_up RENDERED — creates the overlay's Namespace with its labels
# (Pod Security "restricted") before anything else, the way a long-lived
# cluster already has it, so every later pod is admitted against them.
namespace_up() { step "namespace with its Pod Security labels" apply_kinds "$1" Namespace; }

# deps_up NAMESPACE RENDERED — throwaway Postgres and Redis named the way the
# overlay's ConfigMap expects (redis-<env>), the NetworkPolicies that let the
# app reach them, and the stand-in for the SealedSecret.
deps_up() {
  local ns=$1 rendered=$2 redis_host
  redis_host=$(python3 - "$rendered" <<'PY'
import sys, yaml
from urllib.parse import urlparse
cm = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "ConfigMap")
print(urlparse(cm["data"]["REDIS_URL"]).hostname)
PY
)
  step "start Postgres + Redis ($redis_host)" bash -c '
    cat "$1/deps.yaml" "$1/deps-services.yaml" | sed "s/redis-staging/$3/g" |
      kubectl -n "$2" apply -f - -f "$1/deps-netpol.yaml"' _ "$HARNESS_DIR/fixtures" "$ns" "$redis_host" || return 1
  # Secrets are SealedSecrets in real clusters; use the test stand-in.
  kubectl -n "$ns" apply -f "$HARNESS_DIR/fixtures/app-secret.yaml" >/dev/null
  step "Postgres ready" kubectl -n "$ns" wait --for=condition=Ready pod/app-db --timeout=180s
}

# jenkins_run_migrations NAMESPACE — runMigrations() from the Jenkinsfile, same
# command and flags. The ConfigMap and NetworkPolicies it relies on must
# already be applied, as on any deploy after the first.
jenkins_run_migrations() {
  local ns=$1 pod=my-app-migrate-verify overrides
  overrides=$(sed -e "s|__NAME__|$pod|" -e "s|__IMAGE__|$DEPLOY_IMAGE|" "$REPO_ROOT/k8s/migrations/migrate-pod-overrides.json")
  kubectl run "$pod" --namespace="$ns" --image="$DEPLOY_IMAGE" --labels=app=my-app-migrate \
    --rm --restart=Never --attach=true --overrides="$overrides"
}

# smoke_through_service NAMESPACE LOCAL_PORT [LABEL] — port-forwards the my-app
# Service and runs the smoke tests the way runSmokeTests() does.
smoke_through_service() {
  local ns=$1 port=$2 label=${3:+ ($3)}
  kubectl -n "$ns" port-forward svc/my-app "$port:80" >/dev/null 2>&1 & pf_pid=$!
  step "service reachable$label" wait_http "http://127.0.0.1:$port/health/live" 30
  [ -d "$REPO_ROOT/tests/node_modules" ] || (cd "$REPO_ROOT/tests" && npm ci --no-audit --no-fund >&2)
  run_smoke() { (cd "$REPO_ROOT/tests" && BASE_URL="http://127.0.0.1:$port" npm run test:smoke); }
  step "smoke tests$label" run_smoke
  kill "$pf_pid" 2>/dev/null; pf_pid=""
}

# dump_cluster_state NAMESPACE — what a person would look at first.
dump_cluster_state() {
  log "cluster state in $1:"
  kubectl -n "$1" get rollouts,deploy,rs,pods -o wide >&2 2>/dev/null
  kubectl -n "$1" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 40 >&2
}
