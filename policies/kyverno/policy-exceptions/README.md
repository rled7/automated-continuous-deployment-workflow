# Policy Exceptions

This directory contains Kyverno `PolicyException` resources (Kyverno v1.10+
feature). A `PolicyException` allows a specific workload to bypass a policy
**without weakening the policy globally**.

## When to Use a PolicyException

Use a `PolicyException` when:

- A workload **legitimately** violates a policy and **cannot be refactored** in
  the short term (e.g., a third-party Helm chart you do not control, a legacy
  database container that writes to its root filesystem).
- The exception is **temporary** — you intend to remove it once the workload is
  updated or replaced.
- The exception has been **reviewed** by a platform team member and is
  **documented** with a justification and expiry date.

Do NOT use a `PolicyException` to permanently exempt a workload from security
controls. If an exception is still present after its expiry date, it must be
renewed with fresh justification or the workload must be fixed.

## File Naming Convention

```
<policy-name>-<reason>.yaml
```

Examples:
- `require-resource-limits-legacy-batch-job.yaml`
- `disallow-privileged-containers-cni-plugin.yaml`
- `require-pod-probes-third-party-operator.yaml`

## Required Fields

Every `PolicyException` **must** have:

1. An **`expiry` annotation** in ISO 8601 date format (`YYYY-MM-DD`). When the
   expiry date passes, the exception must be renewed or the workload fixed.
2. A **`reason` annotation** explaining why the exception is needed.
3. A **`reviewed-by` annotation** naming the platform team member who approved it.

```yaml
metadata:
  annotations:
    policies.kyverno.io/expiry: "2026-09-01"
    policies.kyverno.io/reason: >-
      This workload is a third-party Helm chart (vendor/chart@1.2.3) that does
      not support readOnlyRootFilesystem. Upgrade to chart@2.0.0 (planned
      2026-08-15) will resolve this. Ticket: INFRA-1234.
    policies.kyverno.io/reviewed-by: "platform-team/alice"
```

## Applying an Exception

```bash
# Apply a specific exception
kubectl apply -f policies/kyverno/policy-exceptions/<policy-name>-<reason>.yaml

# Verify the exception was created
kubectl get policyexception -n <namespace>

# Check that the previously-blocked workload now passes admission
kubectl describe policyexception <name> -n <namespace>
```

## Reviewing Expiry

Run this command periodically (or add it to a cron job / Grafana alert) to
find exceptions that are approaching or past their expiry date:

```bash
kubectl get policyexception -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.metadata.annotations.policies\.kyverno\.io/expiry}{"\n"}{end}'
```

## Example

See `example-exception.yaml.disabled` in this directory for a complete working
example. Rename to `.yaml` to apply it to the cluster (ensure you update
the namespace, policy name, and workload references first).

## Reference

- [Kyverno PolicyException docs](https://kyverno.io/docs/writing-policies/exceptions/)
- Promotion criteria: see `../README.md` → "Promotion criteria" section
- Promotion lifecycle: see `../../docs/policy-promotion.md`
