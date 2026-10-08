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
# A failed step also records the last $STEP_TAIL_LINES lines of its output, so
# results.json usually says why without opening the stage log.
STEPS_FILE="${STEPS_FILE:-/dev/null}"
STEP_FAILURES=0
STEP_TAIL_LINES="${STEP_TAIL_LINES:-30}"
step() {
  local name=$1; shift
  local start rc out
  start=$(date +%s)
  log "── step: $name"
  # A file, not a pipe: the command must run in this shell so variables it
  # sets (and traps that read them) still work.
  out=$(mktemp)
  "$@" > "$out" 2>&1
  rc=$?
  cat "$out" >&2
  local status=pass tail=""
  if [ $rc -ne 0 ]; then
    status=fail; STEP_FAILURES=$((STEP_FAILURES + 1))
    tail=$(tail -n "$STEP_TAIL_LINES" "$out")
  fi
  rm -f "$out"
  jq -nc --arg name "$name" --arg status "$status" --argjson rc "$rc" \
    --argjson secs "$(( $(date +%s) - start ))" --arg tail "$tail" \
    '{name:$name,status:$status,exit_code:$rc,seconds:$secs}
     + (if $tail != "" then {output_tail:$tail} else {} end)' >> "$STEPS_FILE"
  log "   $status ($name)"
  return $rc
}

# finish_stage — call last in a stage script; exits non-zero if any step failed.
finish_stage() { [ "$STEP_FAILURES" -eq 0 ]; exit $?; }

# skip_stage REASON — marks the whole stage as skipped (exit code 3).
skip_stage() { log "SKIP: $*"; echo "$*" > "${STAGE_SKIP_FILE:-/dev/null}"; exit 3; }

# pull_official IMAGE:TAG — pulls a Docker Hub image through the mirror
# (official images like node:20-alpine and namespaced ones like
# jenkins/jenkins) and tags it under its normal name so Dockerfiles resolve it
# locally.
pull_official() {
  local img=$1 src
  docker image inspect "$img" >/dev/null 2>&1 && return 0
  case "$img" in
    */*) src="${IMAGE_MIRROR%/library}/$img" ;;
    *)   src="$IMAGE_MIRROR/$img" ;;
  esac
  docker pull -q "$src" >/dev/null && docker tag "$src" "$img"
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

# render_overlay NAME [OUT_NAME] — renders k8s/overlays/NAME the way
# deployToKubernetes() deploys it (image set to $DEPLOY_IMAGE, version label
# from its tag) into the results dir as OUT_NAME.yaml and prints the path.
# Works on a temp copy so the repo's kustomization.yaml is never modified.
render_overlay() {
  local out="$RESULTS_DIR/rendered/${2:-$1}.yaml" tmp rc
  mkdir -p "$RESULTS_DIR/rendered"
  tmp=$(mktemp -d)
  cp -R "$REPO_ROOT/k8s" "$tmp/k8s"
  (cd "$tmp/k8s/overlays/$1" &&
    kustomize edit set image "my-app=$DEPLOY_IMAGE" &&
    kustomize edit add label "version:${DEPLOY_IMAGE##*:}" --without-selector --include-templates &&
    kustomize build . > "$out")
  rc=$?
  rm -rf "$tmp"
  [ $rc -eq 0 ] && echo "$out"
}

# migrate_pod_yaml NAMESPACE IMAGE NAME — the migration pod runMigrations() in
# the Jenkinsfile creates. Built offline the way `kubectl run --overrides` builds
# it (the pod kubectl run would generate, JSON-merge-patched with the overrides
# file), since kubectl itself needs a live API server for that. The
# cluster-real stage runs the real kubectl command.
migrate_pod_yaml() {
  python3 - "$1" "$2" "$3" "$REPO_ROOT/k8s/migrations/migrate-pod-overrides.json" <<'PY'
import json, sys, yaml
ns, image, name, overrides_path = sys.argv[1:]
overrides = json.loads(open(overrides_path).read().replace("__NAME__", name).replace("__IMAGE__", image))

def merge(target, patch):  # RFC 7396 JSON merge patch, as kubectl --override-type=merge
    if not isinstance(patch, dict):
        return patch
    target = dict(target) if isinstance(target, dict) else {}
    for k, v in patch.items():
        if v is None:
            target.pop(k, None)
        else:
            target[k] = merge(target.get(k), v)
    return target

pod = {
    "apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": name, "namespace": ns, "labels": {"app": "my-app-migrate"}},
    "spec": {"containers": [{"name": name, "image": image}], "restartPolicy": "Never"},
}
print(yaml.safe_dump(merge(pod, overrides), sort_keys=False))
PY
}

# Sandboxes that intercept HTTPS (e.g. Claude Code cloud sessions) need their
# CA inside image builds, or npm and Java downloads fail. HARNESS_CA_BUNDLE (a
# PEM file) and HARNESS_JAVA_TRUSTSTORE (a JKS) are auto-detected in Claude
# Code cloud sessions and empty elsewhere.
if [ -f /root/.ccr/ca-bundle.crt ]; then
  HARNESS_CA_BUNDLE="${HARNESS_CA_BUNDLE:-/root/.ccr/ca-bundle.crt}"
  HARNESS_JAVA_TRUSTSTORE="${HARNESS_JAVA_TRUSTSTORE:-$([ -f /etc/ssl/certs/java/cacerts ] && echo /etc/ssl/certs/java/cacerts)}"
fi

# docker_build DOCKERFILE CONTEXT [docker build args...] — builds an image like
# `docker buildx build --load`, adding the sandbox trust above to every build
# stage except the last, so it never reaches the final image.
docker_build() {
  local dockerfile=$1 context=$2; shift 2
  local args=() trust
  if [ -n "${HARNESS_CA_BUNDLE:-}${HARNESS_JAVA_TRUSTSTORE:-}" ]; then
    trust=$(mktemp -d)
    [ -n "${HARNESS_CA_BUNDLE:-}" ] && cp "$HARNESS_CA_BUNDLE" "$trust/ca.crt"
    [ -n "${HARNESS_JAVA_TRUSTSTORE:-}" ] && cp "$HARNESS_JAVA_TRUSTSTORE" "$trust/cacerts"
    log "adding sandbox CA to the build stages of $(basename "$dockerfile")"
    awk -v last="$(grep -c '^FROM' "$dockerfile")" -v pem="${HARNESS_CA_BUNDLE:+1}" -v jks="${HARNESS_JAVA_TRUSTSTORE:+1}" '
      { print }
      /^FROM/ && ++n < last {
        print "COPY --from=harness-trust . /tmp/harness-trust/"
        if (pem) print "ENV NODE_EXTRA_CA_CERTS=/tmp/harness-trust/ca.crt npm_config_cafile=/tmp/harness-trust/ca.crt"
        if (jks) print "ENV JAVA_OPTS=-Djavax.net.ssl.trustStore=/tmp/harness-trust/cacerts"
      }' "$dockerfile" > "$trust/Dockerfile"
    dockerfile="$trust/Dockerfile"
    args+=(--build-context "harness-trust=$trust")
  fi
  DOCKER_BUILDKIT=1 docker buildx build --load -q -f "$dockerfile" "${args[@]}" "$@" "$context"
}
