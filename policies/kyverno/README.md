# Kyverno Cluster Policies

This directory contains Kyverno `ClusterPolicy` resources applied via the
`kyverno-policies` Argo CD Application (sync wave 10, after Kyverno CRDs).

## Policies

| Policy | Enforcement | Scope | Summary |
|--------|-------------|-------|---------|
| `require-resource-limits` | **Audit** | All namespaces (excl. kube-system, kyverno) | Every container must set CPU + memory requests and limits |
| `require-labels` | **Audit** | `production`, `staging` | Deployments and Rollouts must carry `app`, `env`, `version` labels |
| `disallow-latest-tag` | **Enforce** | `production` only | Images must use a pinned tag; `:latest` or untagged images are rejected |
| `require-readonly-rootfs` | **Audit** | `production`, `staging` | Containers must set `securityContext.readOnlyRootFilesystem: true` |
| `verify-image-signatures` | **Audit** | `production` only | Images must be cosign-signed (Fulcio + Rekor keyless) |

## Audit → Enforce Promotion Path

Policies start in `Audit` mode to avoid breaking existing workloads. After the
initial rollout:

1. **Monitor violations** using `kubectl get policyreport -A` and the Kyverno
   dashboard / Grafana. Aim for zero violations for one full release cycle.
2. **Fix workloads** — add missing labels, resource limits, or security
   contexts as needed.
3. **Promote to Enforce** by changing `validationFailureAction: Audit` →
   `validationFailureAction: Enforce` in the policy YAML, then PR + merge.
   Argo CD will apply the change; Kyverno will start blocking violations.
4. **Exception workflow**: use a Kyverno `PolicyException` resource (separate
   file) for any workload that cannot be fixed immediately. Exceptions require
   justification and an expiry date in a comment.

## Notes

- `disallow-latest-tag` is **Enforce** from day one — CI should always tag
  production images with the git SHA or semver. Staging is exempt.
- `verify-image-signatures` requires images to be signed with cosign in CI
  before switching to Enforce. See the policy file header for prerequisites.
- Policies only apply to namespaces listed in the `match` block. Platform
  namespaces (`kube-system`, `kyverno`, `cert-manager`, etc.) are not
  restricted by the app-focused policies.
