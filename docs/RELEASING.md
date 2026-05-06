# Release Guide

This project uses **tag-based SemVer releases** (`vMAJOR.MINOR.PATCH`).

---

## Versioning

We follow [Semantic Versioning 2.0.0](https://semver.org/):

| Increment | When |
|-----------|------|
| `PATCH` (`v1.2.3 → v1.2.4`) | Backwards-compatible bug fix |
| `MINOR` (`v1.2.3 → v1.3.0`) | New backwards-compatible feature |
| `MAJOR` (`v1.2.3 → v2.0.0`) | Breaking change |

---

## Cutting a release

Use the helper script — it validates the version, bumps `app/package.json`, commits, and tags:

```bash
./scripts/release.sh 1.2.3
```

The script will print the push command to run after you have reviewed the commit and tag:

```bash
git push --follow-tags
```

Pushing the tag to `origin` will trigger the Jenkins release pipeline (once the release stage is added — see the note below).

### Manual steps (if not using the script)

```bash
# 1. Ensure you are on an up-to-date main branch
git checkout main && git pull

# 2. Bump version in app/package.json
npm version 1.2.3 --no-git-tag-version --prefix app

# 3. Commit
git add app/package.json
git commit -m "chore(release): v1.2.3"

# 4. Tag
git tag -a v1.2.3 -m "Release v1.2.3"

# 5. Push commit + tag
git push --follow-tags
```

---

## Recommended Jenkinsfile release stage (sketch)

> **Note:** This stage does not yet exist in the Jenkinsfile — it will be added in a subsequent build. The sketch below documents the intended design.

```groovy
stage('Release') {
    // Runs only when a vX.Y.Z tag is pushed
    when { tag pattern: /^v\d+\.\d+\.\d+$/, comparator: 'REGEXP' }
    steps {
        script {
            def version = env.TAG_NAME          // e.g. "v1.2.3"
            def image   = "${DOCKER_REGISTRY}/my-app:${version}"

            // Build & push a versioned Docker image
            docker.withRegistry("https://${DOCKER_REGISTRY}", 'docker-registry-creds') {
                def img = docker.build(image, '-f docker/Dockerfile .')
                img.push()
                img.push('latest')
            }

            // Deploy to production using the versioned image
            deployToKubernetes('production', image)

            // Create a GitHub Release via the API or gh CLI
            sh "gh release create ${version} --generate-notes"
        }
    }
}
```

---

## Changelog

Update `CHANGELOG.md` before cutting each release. Use the established format (see existing Build entries for style).

---

## Hotfix releases

See `docs/runbook.md` — Hotfix procedure. Hotfixes produce a `PATCH` increment and branch from `main`, not `develop`.
