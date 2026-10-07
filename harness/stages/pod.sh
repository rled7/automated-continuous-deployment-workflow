#!/usr/bin/env bash
# Run the staging Deployment as a real pod with podman kube play, next to a
# throwaway Postgres and Redis, and check what Kubernetes would check:
# migrations, securityContext, startup/readiness probes, then the smoke tests.
# Needs podman (no Kubernetes). KEEP=1 leaves everything running afterwards.
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"

command -v podman >/dev/null || skip_stage "podman not installed"
ensure_docker || exit 1
docker image inspect "$DEPLOY_IMAGE" >/dev/null 2>&1 || { log "image $DEPLOY_IMAGE missing; run the image stage first"; exit 1; }
need_tools kustomize || exit 1

NET=verify
WORK=$(mktemp -d)
DEPS="$HARNESS_DIR/fixtures/deps.yaml"
APP_PLAY="$WORK/app.yaml"

teardown() {
  podman logs my-app-pod-my-app > "$RESULTS_DIR/logs/pod-app-container.log" 2>&1 || true
  if [ "${KEEP:-0}" = 1 ]; then log "KEEP=1: leaving pods running"; return; fi
  podman kube down "$APP_PLAY" >/dev/null 2>&1
  podman kube down "$DEPS" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap teardown EXIT

step "load image into podman" bash -c "docker save '$DEPLOY_IMAGE' | podman load -q" || finish_stage
podman network exists "$NET" || podman network create "$NET" >/dev/null

# Leftovers from an interrupted run would make kube play fail.
podman kube down "$DEPS" >/dev/null 2>&1
step "start Postgres + Redis" podman kube play --network "$NET" "$DEPS" || finish_stage
step "Postgres ready" timeout 90 bash -c \
  'until podman exec app-db-postgres pg_isready -q -U appuser -d appdb; do sleep 2; done' || finish_stage

# The staging ConfigMap + Deployment exactly as rendered for deploy, plus the
# stand-in secret. Services/Ingress/NetworkPolicies need a real cluster.
rendered=$(render_overlay staging) || exit 1
python3 - "$rendered" "$HARNESS_DIR/fixtures/app-secret.yaml" > "$APP_PLAY" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] in ("ConfigMap", "Deployment")]
docs += [d for d in yaml.safe_load_all(open(sys.argv[2])) if d]
print(yaml.safe_dump_all(docs, sort_keys=False))
PY

# The pod runMigrations() in the Jenkinsfile creates, with the staging
# ConfigMap and the stand-in secret.
MIGRATE_PLAY="$WORK/migrate.yaml"
{
  python3 - "$APP_PLAY" <<'PY'
import sys, yaml
print(yaml.safe_dump_all([d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] != "Deployment"], sort_keys=False))
PY
  echo ---
  migrate_pod_yaml staging "$DEPLOY_IMAGE" my-app-migrate-verify
} > "$MIGRATE_PLAY"
run_migrations() {
  local ctr=my-app-migrate-verify-my-app-migrate-verify rc
  podman kube down "$MIGRATE_PLAY" >/dev/null 2>&1
  podman kube play --network "$NET" "$MIGRATE_PLAY" >/dev/null || return 1
  rc=$(podman wait "$ctr")
  podman logs "$ctr" >&2
  podman kube down "$MIGRATE_PLAY" >/dev/null 2>&1
  return "$rc"
}
step "migrations (pod from runMigrations())" run_migrations
if [ $? -ne 0 ]; then
  # Keep going with migrations from source so the later checks still say something.
  log "falling back to running migrations from app/ source"
  [ -d "$REPO_ROOT/app/node_modules" ] || (cd "$REPO_ROOT/app" && npm ci --no-audit --no-fund >/dev/null)
  db_ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' app-db-postgres)
  (cd "$REPO_ROOT/app" && DB_HOST=$db_ip DB_PASSWORD=verify-only-password \
    node node_modules/.bin/knex migrate:latest --knexfile=knexfile.js) >&2 ||
    { log "fallback migrations failed too"; finish_stage; }
fi

podman kube down "$APP_PLAY" >/dev/null 2>&1
step "start app pod (kube play staging Deployment)" podman kube play --network "$NET" "$APP_PLAY" || finish_stage

ctr=my-app-pod-my-app
app_ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$ctr")
log "app container $ctr at $app_ip"

security_context_applied() {
  local ro user
  ro=$(podman inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$ctr")
  user=$(podman inspect -f '{{.Config.User}}' "$ctr")
  log "readOnlyRootFilesystem=$ro user=$user"
  [ "$ro" = true ] && [ "${user%%:*}" = 1000 ]
}
step "securityContext applied (read-only rootfs, uid 1000)" security_context_applied

# startupProbe allows 30 x 10s; readiness should follow within a minute.
step "startupProbe /health/live" wait_http "http://$app_ip:3000/health/live" 300
step "readinessProbe /health/ready" wait_http "http://$app_ip:3000/health/ready" 60 || \
  curl -s -m 3 "http://$app_ip:3000/health/ready" >&2

still_running() { [ "$(podman inspect -f '{{.State.Status}}' "$ctr")" = running ]; }
step "container still running" still_running

# tests/ deps installed the way runSmokeTests() in the Jenkinsfile does it.
install_smoke_deps() { (cd "$REPO_ROOT/tests" && npm ci --no-audit --no-fund); }
if ! step "smoke test deps (npm ci, as Jenkins)" install_smoke_deps; then
  log "falling back to npm install so the smoke tests can still run"
  (cd "$REPO_ROOT/tests" && npm install --no-audit --no-fund --no-package-lock >&2)
fi

# Same npm script runSmokeTests() calls.
run_smoke() { (cd "$REPO_ROOT/tests" && BASE_URL="http://$app_ip:3000" npm run test:smoke); }
step "smoke tests" run_smoke

finish_stage
