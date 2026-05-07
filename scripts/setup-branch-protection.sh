#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-branch-protection.sh — Configure GitHub branch protection via gh API.
# Idempotent: re-running just patches to the desired state.
#
# GitHub branch protection settings live outside the repo's files; this script
# is the canonical "infra-as-code" for them. Run it once after creating the repo
# and again whenever you bump required status checks.
#
# Usage: ./scripts/setup-branch-protection.sh [<owner>/<repo>]
#   If repo arg is omitted, derives it from `gh repo view`.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

command -v gh >/dev/null || { echo "ERROR: gh CLI not on PATH"; exit 1; }
gh auth status >/dev/null || { echo "ERROR: gh CLI not authenticated; run 'gh auth login'"; exit 1; }

echo "▶ Configuring branch protection on ${REPO}"

# ── main: strict gating, required reviews, linear history ────────────────────
echo "  → main"
gh api -X PUT "/repos/${REPO}/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Lint + Unit Tests",
      "Validate PR title",
      "continuous-integration/jenkins/branch"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "restrictions": null
}
EOF

# ── develop: lighter — direct pushes allowed, status checks still required ──
echo "  → develop"
gh api -X PUT "/repos/${REPO}/branches/develop/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<'EOF' || echo "    (develop branch may not exist yet — skipping)"
{
  "required_status_checks": {
    "strict": false,
    "contexts": [
      "Lint + Unit Tests",
      "continuous-integration/jenkins/branch"
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "restrictions": null
}
EOF

echo "✓ Branch protection configured. Verify in GitHub repo settings → Branches."
