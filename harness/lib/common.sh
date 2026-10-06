# shellcheck shell=bash
# Shared helpers for harness stages. Source this file; do not execute it.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$HARNESS_DIR/.results}"
BIN_DIR="$HARNESS_DIR/.bin"
export PATH="$BIN_DIR:$PATH"

# Docker Hub rate-limits anonymous pulls from shared IPs (CI runners, cloud
# sandboxes). Official images are pulled through Google's public mirror instead.
IMAGE_MIRROR="${IMAGE_MIRROR:-mirror.gcr.io/library}"

# Name of the image the image stage builds and later stages run.
APP_IMAGE="${APP_IMAGE:-my-app:verify}"

mkdir -p "$RESULTS_DIR" "$BIN_DIR"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# step NAME CMD... — runs one check inside a stage, records pass/fail as a JSON
# line in $STEPS_FILE, and keeps going so one failure doesn't hide the next.
STEPS_FILE="${STEPS_FILE:-/dev/null}"
STEP_FAILURES=0
step() {
  local name=$1; shift
  local start rc
  start=$(date +%s)
  log "── step: $name"
  "$@"
  rc=$?
  local status=pass
  if [ $rc -ne 0 ]; then status=fail; STEP_FAILURES=$((STEP_FAILURES + 1)); fi
  jq -nc --arg name "$name" --arg status "$status" --argjson rc "$rc" \
    --argjson secs "$(( $(date +%s) - start ))" \
    '{name:$name,status:$status,exit_code:$rc,seconds:$secs}' >> "$STEPS_FILE"
  log "   $status ($name)"
  return $rc
}

# finish_stage — call last in a stage script; exits non-zero if any step failed.
finish_stage() { [ "$STEP_FAILURES" -eq 0 ]; exit $?; }

# skip_stage REASON — marks the whole stage as skipped (exit code 3).
skip_stage() { log "SKIP: $*"; echo "$*" > "${STAGE_SKIP_FILE:-/dev/null}"; exit 3; }

# pull_official IMAGE:TAG — pulls an official Docker Hub image via the mirror
# and tags it under its normal short name so Dockerfiles resolve it locally.
pull_official() {
  local img=$1
  docker image inspect "$img" >/dev/null 2>&1 && return 0
  docker pull -q "$IMAGE_MIRROR/$img" >/dev/null && docker tag "$IMAGE_MIRROR/$img" "$img"
}

# ensure_docker — succeeds if a Docker daemon is reachable. In throwaway
# sandboxes (running as root, dockerd installed but not started) it starts one.
ensure_docker() {
  docker info >/dev/null 2>&1 && return 0
  if [ "$(id -u)" = 0 ] && command -v dockerd >/dev/null; then
    log "starting dockerd"
    nohup dockerd >"$RESULTS_DIR/dockerd.log" 2>&1 &
    for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && return 0; sleep 1; done
  fi
  log "no Docker daemon available"
  return 1
}

# wait_http URL TIMEOUT_SECS [EXPECTED_STATUS]
wait_http() {
  local url=$1 timeout=$2 want=${3:-200} got
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$url" || true)
    [ "$got" = "$want" ] && return 0
    sleep 2
  done
  log "timed out waiting for $url (last status: ${got:-none}, wanted $want)"
  return 1
}

# Image reference written into the overlays, as Jenkins' deployToKubernetes()
# does with `kustomize edit set image`. Policies reject :latest, so the default
# is a commit-pinned tag.
DEPLOY_IMAGE="${DEPLOY_IMAGE:-my-app:verify-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)}"

# render_overlay NAME — renders k8s/overlays/NAME the way the pipeline deploys
# it (image set to $DEPLOY_IMAGE) into the results dir and prints the path.
# Works on a temp copy so the repo's kustomization.yaml is never modified.
render_overlay() {
  local out="$RESULTS_DIR/rendered/$1.yaml" tmp rc
  mkdir -p "$RESULTS_DIR/rendered"
  tmp=$(mktemp -d)
  cp -R "$REPO_ROOT/k8s" "$tmp/k8s"
  (cd "$tmp/k8s/overlays/$1" && kustomize edit set image "my-app=$DEPLOY_IMAGE" && kustomize build . > "$out")
  rc=$?
  rm -rf "$tmp"
  [ $rc -eq 0 ] && echo "$out"
}
