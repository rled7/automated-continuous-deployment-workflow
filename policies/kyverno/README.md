# Kyverno Cluster Policies

This directory contains Kyverno `ClusterPolicy` resources applied via the
`kyverno-policies` Argo CD Application (sync wave 10, after Kyverno CRDs).

## Promotion criteria

Promotion from **Audit → Enforce** happens after:

1. The policy has been deployed in Audit for ≥ 7 days
2. `kubectl get policyreports -A` shows zero FAIL results for the namespaces it covers
3. No exception has been added (or all exceptions are documented + time-bound)
4. The promotion is reviewed by at least one platform team member (per CODEOWNERS)

See `docs/policy-promotion.md` for the full lifecycle, how to query
`policyreports`, how to write a `PolicyException`, and Kyverno Prometheus metrics.

## Policies

| Policy | Mode | Scope | Summary |
|--------|------|-------|---------|
| `require-resource-limits` | **Enforce** | All namespaces (excl. kube-system, kyverno) | Every container must set CPU + memory requests and limits. Promoted Build 021. |
| `require-labels` | **Enforce** | `production`, `staging` | Deployments and Rollouts must carry `app`, `env`, `version` labels. Promoted Build 021. |
| `require-readonly-rootfs` | **Enforce** | `production`, `staging` | Containers must set `securityContext.readOnlyRootFilesystem: true`. Promoted Build 021. |
| `disallow-latest-tag` | **Enforce** | `production` only | Images must use a pinned tag; `:latest` or untagged images are rejected. Enforce from Build 016. |
| `verify-image-signatures` | **Audit** | `production` only | Images must be cosign-signed (Fulcio + Rekor keyless). Kept Audit — see promotion checklist in file header. |
| `disallow-host-namespaces` | **Enforce** | `production`, `staging` | Forbids `hostNetwork`, `hostPID`, `hostIPC`. New in Build 021. |
| `disallow-privileged-containers` | **Enforce** | `production`, `staging` | Forbids `securityContext.privileged: true`. New in Build 021. |
| `disallow-capabilities` | **Enforce** | `production`, `staging` | Forbids NET_ADMIN, SYS_ADMIN, SYS_PTRACE, SYS_MODULE, NET_RAW. New in Build 021. |
| `require-pod-probes` | **Audit** | `production`, `staging` | Requires `livenessProbe` + `readinessProbe` on all containers. New in Build 021 — soak before Enforce. |

## Policy Exceptions

When a workload legitimately needs to violate a policy, use a Kyverno
`PolicyException` resource **instead of weakening the policy globally**.

See [`policy-exceptions/README.md`](policy-exceptions/README.md) for:

- When to use an exception
- File naming convention: `<policy-name>-<reason>.yaml`
- Required annotations (expiry, reason, reviewed-by)
- A working `example-exception.yaml.disabled` template

## Notes

- Policies only apply to namespaces listed in the `match` block using
  `match.any` resource selectors (Kyverno v1.10+ style — `excludeResources`
  is deprecated). Platform namespaces (`kube-system`, `kyverno`, `cert-manager`,
  `ingress-nginx`) are never restricted by the app-focused policies.
- `disallow-latest-tag` is **Enforce** from day one — CI should always tag
  production images with the git SHA or semver. Staging is exempt.
- `verify-image-signatures` remains in **Audit** until at least 7 days of
  real production deployments show zero FAIL results in PolicyReports. See
  the policy file header for the full promotion checklist.
- `require-pod-probes` is a **new policy** in Build 021 and remains in
  **Audit** per the soak-first policy. Planned promotion: 2026-05-14.
