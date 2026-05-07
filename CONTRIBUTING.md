# Contributing

Thank you for contributing! Please read this guide before opening a PR.

## Setup

Run the bootstrap script — it handles prerequisites, Docker Compose services, Kubernetes namespaces, and `npm ci`:

```bash
./scripts/setup.sh --local   # local Docker Compose stack
./scripts/setup.sh --k8s     # full Kubernetes stack
```

See `README.md` for environment variable requirements (`.env.example`).

## Branch model

```
feature/<short-description>  →  develop  →  main
hotfix/<short-description>   →  main  (then back-merged to develop)
```

- `main` — production-ready, protected. Merges trigger a Jenkins deploy to production.
- `develop` — integration branch. Merges trigger a Jenkins deploy to staging.
- Do **not** commit directly to `main` or `develop`.

## Commit style

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary>

[optional body]
[optional footer: Closes #123]
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`.

## PR process

1. Open a PR against `develop` (or `main` for hotfixes).
2. Fill in the PR template fully — summary, test plan, risk + rollback.
3. At least one approval is required before merge (CODEOWNERS enforced).
4. All CI checks must be green (lint, unit, integration, smoke, SAST, dependency scan).
5. Squash-merge or rebase-merge only; no merge commits on `develop`/`main`.

## Tests

```bash
# Unit + integration (in app/)
npm test
npm run test:integration

# Smoke (in tests/)
cd tests && npm test
```

Coverage thresholds are enforced by Jest (see `app/jest.config.js`): 80% lines, 70% branches, 60% functions.

## Code review

- Be constructive and specific in review comments.
- Prefer suggesting concrete changes over vague feedback.
- Approve only when you are confident the change is safe to deploy.
- If you request changes, re-review promptly after the author has addressed them.
