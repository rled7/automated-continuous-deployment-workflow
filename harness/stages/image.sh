#!/usr/bin/env bash
# Build the production image from docker/Dockerfile and check basic properties
# the Kubernetes manifests rely on.
source "$(dirname "$0")/../lib/common.sh"

ensure_docker || exit 1

# The Dockerfile's base image, pulled via the mirror to dodge Docker Hub limits.
base=$(awk '/^FROM/{print $2; exit}' "$REPO_ROOT/docker/Dockerfile")
step "pull base image $base" pull_official "$base"

step "docker build" docker_build "$REPO_ROOT/docker/Dockerfile" "$REPO_ROOT" \
  -t "$APP_IMAGE" -t "$DEPLOY_IMAGE" || finish_stage

# npm can exit 0 after a failed install ("Exit handler never called"), leaving
# empty package dirs, so check the runtime dependencies are actually loadable.
deps_resolvable() {
  docker run --rm --entrypoint node "$APP_IMAGE" -e '
    const deps = Object.keys(require("./package.json").dependencies);
    const fs = require("fs");
    const missing = deps.filter(d => !fs.existsSync("node_modules/" + d + "/package.json"));
    if (missing.length) { console.error("missing:", missing.join(", ")); process.exit(1); }
    console.error(deps.length + " runtime dependencies resolvable");'
}
step "runtime dependencies installed in image" deps_resolvable

runs_as_non_root() {
  local user; user=$(docker image inspect -f '{{.Config.User}}' "$APP_IMAGE")
  log "image user: ${user:-<root>}"
  [ -n "$user" ] && [ "$user" != root ] && [ "$user" != 0 ]
}
step "image runs as non-root" runs_as_non_root

docker image inspect -f 'size: {{.Size}} bytes' "$APP_IMAGE" >&2

finish_stage
