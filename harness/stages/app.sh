#!/usr/bin/env bash
# Install, lint and unit-test the app — the same commands the Jenkins Lint and
# Unit Tests stages run.
source "$(dirname "$0")/../lib/common.sh"

cd "$REPO_ROOT/app" || exit 1

step "npm ci" npm ci --no-audit --no-fund || finish_stage
step "lint" npm run lint
step "unit tests" npm run test:unit

finish_stage
