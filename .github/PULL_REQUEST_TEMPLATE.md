## Summary

<!-- One or two sentences describing what this PR does and why. -->

## Changes

<!-- Bullet list of the concrete changes made. -->

-

## Test plan

- [ ] Unit tests pass (`npm test` in `app/`)
- [ ] Integration tests pass (`npm run test:integration` in `app/`)
- [ ] Smoke tests pass against the target environment
- [ ] Linting passes (`npm run lint`)
- [ ] Manually verified in staging / local environment

## Risk + rollback plan

**Risk level:** Low / Medium / High

<!-- Describe what could go wrong and how to recover. -->

**Rollback:**
- Automated: Jenkinsfile `post { failure }` block triggers `kubectl rollout undo`.
- Manual: `kubectl rollout undo deployment/my-app -n <namespace>`

## Linked issues

Closes #

## Screenshots (if UI change)

<!-- Attach before/after screenshots or remove this section. -->
