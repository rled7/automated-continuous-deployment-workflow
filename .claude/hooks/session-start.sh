#!/bin/bash
# SessionStart hook for Claude Code cloud sessions: gets the container ready to
# run harness/verify.sh (see harness/README.md) and the app/ and tests/ suites.
# Idempotent: on a resumed session everything below is already in place except
# the Docker daemon, which is started again.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# Node dependencies for the app and the smoke tests.
(cd app && npm install --no-audit --no-fund)
(cd tests && npm install --no-audit --no-fund)

# podman runs the pod stage (podman kube play).
if ! command -v podman >/dev/null && [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
  apt-get install -y -q podman >/dev/null 2>&1 ||
    { apt-get update -q >/dev/null 2>&1 && apt-get install -y -q podman >/dev/null 2>&1; } ||
    echo "session-start: could not install podman; the pod stage will be skipped" >&2
fi

# Pinned harness tools into harness/.bin, and a Docker daemon, using the
# harness's own helpers.
bash -c '
  source harness/lib/common.sh
  source harness/lib/tools.sh
  need_tools kubectl kustomize kubeconform kyverno kwok kwokctl terraform kind
  ensure_docker || echo "session-start: no Docker daemon; image, pod, terraform and cluster stages need one" >&2
'

# Put the pinned tools first on PATH for the session.
echo "export PATH=\"$CLAUDE_PROJECT_DIR/harness/.bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
