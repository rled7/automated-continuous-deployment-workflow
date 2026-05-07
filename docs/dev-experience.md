# Developer Experience

How the local + PR feedback loop works and how to keep it fast.

## Pre-commit hooks

Two hooks run automatically on every `git commit`:

| Hook | Tool | What it does |
|---|---|---|
| `pre-commit` | `lint-staged` | Runs ESLint on staged `*.js` files; runs Prettier on staged `*.{json,md,yml,yaml}` files. Auto-fixes when possible. Blocks the commit if anything still fails. |
| `commit-msg` | `commitlint` | Validates the commit message against [Conventional Commits](https://www.conventionalcommits.org). Allowed scopes: `app`, `infra`, `ci`, `docs`, `chore`, `test`, `sec`. |

Hooks are installed by Husky. The `prepare` script in the root `package.json` runs `husky` automatically on `npm install`, so the first time you set up the repo:

```bash
npm install            # at repo root — installs husky, lint-staged, commitlint, prettier
cd app && npm install  # installs the app's deps separately
```

## What happens on a bad commit

```bash
$ git commit -m "broke stuff"
✖   subject may not be empty [subject-empty]
✖   type may not be empty [type-empty]

$ git commit -m "fix: app/server returns 500"
[scope-enum] scope must be one of [app, infra, ci, docs, chore, test, sec]

$ git commit -m "fix(app): /api/items returns 500 when name is empty"
✓   passes commit-msg
✓   passes pre-commit (after auto-fix)
[claude/plan-next-steps-F1i5E abc1234] fix(app): /api/items returns 500 when name is empty
```

## Bypassing the hooks (rare!)

```bash
git commit --no-verify -m "..."
```

Acceptable reasons:
- Recovering from a broken hook setup (then fix the hook).
- An emergency hotfix that genuinely cannot wait for the linter.

Not acceptable:
- "It's just a small change."
- "Linter is too strict."

If a rule is too strict, fix the rule (`app/.eslintrc.json` or `commitlint.config.js`) — don't normalize bypassing.

## Manual checks

```bash
# Run the same checks the hooks run
cd app && npm run lint
npx prettier --check .
echo "fix(app): test message" | npx commitlint
```

## The two-pipeline feedback loop

Every PR triggers two CI systems in parallel:

| System | What runs | Time | Required for merge? |
|---|---|---|---|
| **GitHub Actions** (`.github/workflows/pr-checks.yml`) | Lint + unit tests | ~30–60s | Yes (status check `Lint + Unit Tests`) |
| **Jenkins** (`Jenkinsfile`) | Full pipeline: SAST + SCA + integration + build + image scan + sign + deploy → PR preview | ~10–25 min | Yes (status check `continuous-integration/jenkins/branch`) |

Why both?
- **GH Actions** is fast and cheap. Catches "did you break the unit tests" in under a minute.
- **Jenkins** does the heavy lifting (image build, signing, k8s deploy to a PR-preview namespace). Slow but comprehensive.

When a developer pushes a PR commit, both run; the developer sees GH Actions feedback first and can fix lint/test issues without waiting for Jenkins.

## Conventional Commits format

```
<type>(<scope>): <subject>

<body — optional, wrap at 72 chars>

<footer — optional, "BREAKING CHANGE:", "Closes #N">
```

| Type | Use for |
|---|---|
| `feat` | new feature |
| `fix` | bug fix |
| `chore` | maintenance, no production code change |
| `docs` | docs only |
| `test` | tests only |
| `refactor` | code restructure, no behavior change |
| `perf` | performance improvement |
| `ci` | CI/CD config change |
| `sec` | security fix |

Header max length: 100 chars. Subject must start with a letter.

## Branch protection

See `docs/branch-protection.md` for the gating rules + how to set them up.
