# Branch Protection

GitHub branch protection rules (required status checks, reviewer requirements, restrictions on force-push and deletion) cannot be expressed in repo files. They live in GitHub repository settings and can only be set via the UI or the GitHub API.

This repo's protection state is codified in `scripts/setup-branch-protection.sh`. Run it once after creating the repo, and again any time you change the required status check list.

## What it sets up

### `main`

| Setting | Value |
|---|---|
| Required status checks | `Lint + Unit Tests` (GitHub Actions), `Validate PR title`, `continuous-integration/jenkins/branch` |
| Strict checks (must be up to date) | `true` |
| Required reviewers | 1 |
| Code owner review required | `true` |
| Dismiss stale reviews on push | `true` |
| Linear history required | `true` |
| Force push allowed | `false` |
| Branch deletion allowed | `false` |
| Conversation resolution required | `true` |

### `develop`

Lighter — direct pushes are allowed but status checks still gate merges:

| Setting | Value |
|---|---|
| Required status checks | `Lint + Unit Tests`, `continuous-integration/jenkins/branch` |
| Strict checks | `false` |
| Required reviewers | none |
| Force push allowed | `false` |
| Branch deletion allowed | `false` |

## Run

```bash
./scripts/setup-branch-protection.sh
```

The script auto-detects the repo from `gh repo view`. Pass `<owner>/<repo>` explicitly if running from outside the working tree:

```bash
./scripts/setup-branch-protection.sh rled7/automated-continuous-deployment-workflow
```

## Emergency hotfix bypass

When production is on fire and the rules are blocking a hotfix, an admin can:

1. Temporarily disable the protection: GitHub UI → Settings → Branches → edit rule → uncheck "Restrict who can push" + "Require pull request reviews" → save.
2. Push the hotfix.
3. **Re-enable immediately** by re-running this script.

Document the bypass in the postmortem.

## Why this lives in a script, not a Terraform module

This repo deliberately avoids Terraform/Pulumi (per the original "keep it simple" tooling rationale — see `docs/tech-stack.md`). For a repo with one or two GitHub repositories under management, a `gh api` script is sufficient and reviewable in 80 lines. If you ever manage 20+ repos, migrate to a Terraform `github` provider.
