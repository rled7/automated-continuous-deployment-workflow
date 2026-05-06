#!/usr/bin/env bash
# scripts/release.sh — cut a SemVer release
#
# Usage:  ./scripts/release.sh 1.2.3
#
# What it does:
#   1. Validates the version argument is MAJOR.MINOR.PATCH
#   2. Bumps the version in app/package.json using `node -e`
#   3. Commits with message "chore(release): vX.Y.Z"
#   4. Creates an annotated tag vX.Y.Z
#   5. Prints the push command — you must run it manually after reviewing.
#
# What it does NOT do:
#   - Push to origin (intentional — review the commit and tag first)
#   - Modify the Jenkinsfile or any CI configuration

set -euo pipefail

# ── Argument validation ────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 MAJOR.MINOR.PATCH" >&2
  exit 1
fi

VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be MAJOR.MINOR.PATCH (e.g. 1.2.3), got: '$VERSION'" >&2
  exit 1
fi

TAG="v${VERSION}"

# ── Repo root check ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_JSON="${REPO_ROOT}/app/package.json"

if [[ ! -f "$PACKAGE_JSON" ]]; then
  echo "Error: could not find app/package.json at ${PACKAGE_JSON}" >&2
  exit 1
fi

# ── Ensure working tree is clean ───────────────────────────────────────────────
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "Error: working tree has uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

# ── Ensure tag does not already exist ─────────────────────────────────────────
if git -C "$REPO_ROOT" tag --list | grep -qx "$TAG"; then
  echo "Error: tag '${TAG}' already exists." >&2
  exit 1
fi

# ── Bump version in app/package.json ──────────────────────────────────────────
echo "Bumping app/package.json to ${VERSION} ..."
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('${PACKAGE_JSON}', 'utf8'));
pkg.version = '${VERSION}';
fs.writeFileSync('${PACKAGE_JSON}', JSON.stringify(pkg, null, 2) + '\n');
"

# ── Commit ─────────────────────────────────────────────────────────────────────
echo "Creating release commit ..."
git -C "$REPO_ROOT" add app/package.json
git -C "$REPO_ROOT" commit -m "chore(release): ${TAG}"

# ── Annotated tag ─────────────────────────────────────────────────────────────
echo "Tagging ${TAG} ..."
git -C "$REPO_ROOT" tag -a "$TAG" -m "Release ${TAG}"

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "Release ${TAG} is ready locally."
echo "Review the commit and tag, then push with:"
echo ""
echo "    git push --follow-tags"
echo ""
