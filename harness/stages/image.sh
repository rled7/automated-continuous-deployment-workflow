#!/usr/bin/env bash
# Build the production image from docker/Dockerfile and check basic properties
# the Kubernetes manifests rely on.
source "$(dirname "$0")/../lib/common.sh"

ensure_docker || exit 1

# The Dockerfile's base image, pulled via the mirror to dodge Docker Hub limits.
base=$(awk '/^FROM/{print $2; exit}' "$REPO_ROOT/docker/Dockerfile")
step "pull base image $base" pull_official "$base"

# Sandboxes that intercept HTTPS (e.g. Claude Code cloud sessions) need their CA
# inside the build or npm ci fails. Set HARNESS_CA_BUNDLE to a PEM file; it is
# auto-detected in Claude Code cloud sessions. The CA is added only to build
# stages, never to the final runtime stage.
HARNESS_CA_BUNDLE="${HARNESS_CA_BUNDLE:-$([ -f /root/.ccr/ca-bundle.crt ] && echo /root/.ccr/ca-bundle.crt)}"
dockerfile="$REPO_ROOT/docker/Dockerfile"
build_args=()
if [ -n "$HARNESS_CA_BUNDLE" ]; then
  log "adding CA bundle $HARNESS_CA_BUNDLE to build stages"
  ca_dir=$(mktemp -d); cp "$HARNESS_CA_BUNDLE" "$ca_dir/ca.crt"
  dockerfile="$ca_dir/Dockerfile"
  awk -v last="$(grep -c '^FROM' "$REPO_ROOT/docker/Dockerfile")" '
    { print }
    /^FROM/ && ++n < last {
      print "COPY --from=harness-ca ca.crt /usr/local/share/harness-ca.crt"
      print "ENV NODE_EXTRA_CA_CERTS=/usr/local/share/harness-ca.crt npm_config_cafile=/usr/local/share/harness-ca.crt"
    }' "$REPO_ROOT/docker/Dockerfile" > "$dockerfile"
  build_args+=(--build-context "harness-ca=$ca_dir")
fi

step "docker build" env DOCKER_BUILDKIT=1 docker buildx build --load -q -f "$dockerfile" "${build_args[@]}" \
  -t "$APP_IMAGE" -t "$DEPLOY_IMAGE" "$REPO_ROOT" || finish_stage

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
