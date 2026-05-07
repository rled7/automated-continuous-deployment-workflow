# PR Preview Environments

Each pull request can get its own ephemeral namespace (`preview-pr-<N>`) that mirrors the staging overlay. This lets reviewers test changes against a live cluster before merge.

## How it works

1. A Jenkins pipeline stage (added in Build 009) calls `scripts/pr-preview-up.sh <PR_NUMBER>` when a PR is opened or updated.
2. The script creates the namespace `preview-pr-<PR_NUMBER>`, builds the staging kustomize overlay, rewrites `namespace: staging` → `namespace: preview-pr-<PR_NUMBER>`, and applies the resulting manifests.
3. When the PR is closed (merged or abandoned) the pipeline calls `scripts/pr-preview-down.sh <PR_NUMBER>`, which deletes the namespace and all resources inside it.

## Namespace lifecycle

| Event               | Action                                              |
|---------------------|-----------------------------------------------------|
| PR opened / updated | `scripts/pr-preview-up.sh $PR_NUMBER`               |
| PR closed           | `scripts/pr-preview-down.sh $PR_NUMBER`             |

## Argo CD scoping

The `AppProject` (`argocd/AppProject.yaml`) allows destinations matching the `preview-*` namespace glob, so Argo CD will not block resources deployed there. Preview namespaces are **not** managed by an Argo CD `Application`; they are created imperatively by the scripts above.

## Manual usage

```bash
# Spin up preview for PR #42
./scripts/pr-preview-up.sh 42

# Check the rollout
kubectl rollout status deploy/my-app -n preview-pr-42

# Tear down when done
./scripts/pr-preview-down.sh 42
```

## Jenkinsfile stage sketch (Build 009 will wire this in)

```groovy
stage('PR Preview') {
  when {
    changeRequest()   // only runs on pull requests
  }
  steps {
    sh "./scripts/pr-preview-up.sh ${env.CHANGE_ID}"
  }
  post {
    // Tear down on PR close — triggered by a separate webhook-driven build
    cleanup {
      sh "./scripts/pr-preview-down.sh ${env.CHANGE_ID}"
    }
  }
}
```

## Limitations & future improvements

- The namespace rewrite uses `sed`; a cleaner alternative is a kustomize `namePrefix`/`nameSuffix` or a dedicated `namespace` field in a per-PR overlay.
- No ingress is created for the preview namespace by default. Add an `IngressPatch` per PR (or use a wildcard DNS entry like `pr-42.preview.example.com`) for browser-accessible previews.
- Resource quotas on `preview-*` namespaces are recommended to prevent runaway previews from consuming cluster capacity.
