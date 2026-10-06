#!/usr/bin/env bash
# Deploy the staging overlay to a real kind cluster the way the Jenkinsfile
# deploys it (migrations via `kubectl run`, apply, rollout status), with a
# throwaway Postgres/Redis, then run the smoke tests through a port-forward.
# Unlike the pod stage, NetworkPolicies, Services and probes are enforced by
# Kubernetes itself. Needs a host where kind works (your machine, GitHub
# Actions). KEEP=1 leaves the cluster running.
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"

CLUSTER=harness-verify
NS=staging
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-mirror.gcr.io/kindest/node:v1.31.0}"

need_tools kind kubectl kustomize || exit 1
ensure_docker || exit 1
docker image inspect "$DEPLOY_IMAGE" >/dev/null 2>&1 || { log "image $DEPLOY_IMAGE missing; run the image stage first"; exit 1; }

export KUBECONFIG="${KIND_KUBECONFIG:-$(mktemp)}"
pf_pid=""
teardown() {
  [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null
  kubectl -n "$NS" logs deploy/my-app --all-containers --tail=200 > "$RESULTS_DIR/logs/cluster-real-app.log" 2>&1
  [ "${KEEP:-0}" = 1 ] && { log "KEEP=1: kind cluster $CLUSTER left running (KUBECONFIG=$KUBECONFIG)"; return; }
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
}
trap teardown EXIT

kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
step "create kind cluster" kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --wait 180s || finish_stage
step "load app image" kind load docker-image "$DEPLOY_IMAGE" --name "$CLUSTER" || finish_stage

rendered=$(render_overlay "$NS") || exit 1
kubectl create namespace "$NS" >/dev/null
step "start Postgres + Redis" kubectl -n "$NS" apply -f "$HARNESS_DIR/fixtures/deps.yaml" -f "$HARNESS_DIR/fixtures/deps-services.yaml"
# Secrets are SealedSecrets in real clusters; use the test stand-in.
kubectl -n "$NS" apply -f "$HARNESS_DIR/fixtures/app-secret.yaml" >/dev/null
step "Postgres ready" kubectl -n "$NS" wait --for=condition=Ready pod/app-db --timeout=180s || finish_stage

# runMigrations() runs before deployToKubernetes(), so the my-app
# ServiceAccount it names doesn't exist on a first deploy; the overlay's
# ServiceAccount is applied first here so only the command itself is tested.
kubectl -n "$NS" apply -f <(python3 -c 'import sys,yaml; print(yaml.safe_dump_all([d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"]=="ServiceAccount"]))' "$rendered") >/dev/null
step "migrations (runMigrations() from the Jenkinsfile)" kubectl run my-app-migrate \
  --namespace="$NS" --image="$DEPLOY_IMAGE" --rm --restart=Never --attach=true \
  --serviceaccount=my-app \
  -- node node_modules/.bin/knex migrate:latest --knexfile=knexfile.js
if [ $? -ne 0 ]; then
  log "falling back to running migrations from app/ source through a port-forward"
  kubectl -n "$NS" delete pod my-app-migrate --ignore-not-found >/dev/null 2>&1
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

kubectl -n "$NS" port-forward svc/my-app 13000:80 >/dev/null 2>&1 & pf_pid=$!
step "service reachable" wait_http http://127.0.0.1:13000/health/live 30

install_smoke_deps() { (cd "$REPO_ROOT/tests" && npm ci --no-audit --no-fund); }
if ! step "smoke test deps (npm ci, as Jenkins)" install_smoke_deps; then
  (cd "$REPO_ROOT/tests" && npm install --no-audit --no-fund --no-package-lock >&2)
fi
run_smoke() { (cd "$REPO_ROOT/tests" && BASE_URL=http://127.0.0.1:13000 npm run test:smoke); }
step "smoke tests" run_smoke

finish_stage
