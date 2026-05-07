# Kyverno Policy Promotion Guide

This document covers the Audit → Enforce promotion lifecycle for Kyverno
`ClusterPolicies`, how to query `policyreports` for violations, how to write
a `PolicyException` for legitimate violations, and how to use Kyverno's
Prometheus metrics to observe policy impact.

---

## Audit → Enforce Promotion Lifecycle

Kyverno policies start in `Audit` mode. In this mode Kubernetes **does not
block** non-compliant resources — it only records violations in `PolicyReport`
objects. This allows teams to discover violations without disrupting workloads.

### Promotion criteria

Before promoting a policy from Audit to Enforce, ALL of the following must be
true:

1. **Soak period**: The policy has been running in Audit for **at least 7 days**
   against real workloads in the target namespaces.
2. **Zero violations**: `kubectl get policyreports -A` shows **zero FAIL results**
   for the namespaces covered by the policy.
3. **Exceptions are documented**: If any `PolicyException` was filed during the
   soak period, it is time-bound (has an expiry annotation) and has been reviewed
   by a platform team member.
4. **Platform review**: The promotion PR is reviewed by at least one platform
   team member (enforced by CODEOWNERS).

### How to promote

1. Open `policies/kyverno/<policy-name>.yaml`.
2. Change `validationFailureAction: Audit` → `validationFailureAction: Enforce`.
3. Update the comment block at the top to record the promotion date and reason.
4. Open a PR, get a platform-team review, and merge. Argo CD applies the change;
   Kyverno starts blocking violations immediately.

---

## Querying PolicyReports for FAIL Results

Kyverno writes admission results into `PolicyReport` (namespace-scoped) and
`ClusterPolicyReport` (cluster-scoped) objects.

### View all violations across all namespaces

```bash
# Summary — one line per PolicyReport
kubectl get policyreport -A

# Detailed — show all FAIL results
kubectl get policyreport -A -o json \
  | jq '.items[] | select(.results != null) | .results[] | select(.result == "fail") | {policy: .policy, rule: .rule, resource: .resources[0].name, namespace: .resources[0].namespace, message: .message}'
```

### Filter by a specific policy

```bash
kubectl get policyreport -A -o json \
  | jq --arg policy "require-resource-limits" \
    '.items[] | .results[] | select(.result == "fail" and .policy == $policy)'
```

### Watch for new violations in real time

```bash
kubectl get policyreport -A -w
```

### Check ClusterPolicyReports (for cluster-scoped resources)

```bash
kubectl get clusterpolicyreport -o json \
  | jq '.items[] | .results[] | select(.result == "fail")'
```

---

## Writing a PolicyException

A `PolicyException` exempts a **specific workload** from a policy rule
**without weakening the policy globally**. Use exceptions sparingly and always
with a time-bound expiry.

### Structure

```yaml
apiVersion: kyverno.io/v2beta1
kind: PolicyException
metadata:
  name: <policy-name>-<reason>
  namespace: <workload-namespace>
  annotations:
    policies.kyverno.io/expiry: "YYYY-MM-DD"        # REQUIRED
    policies.kyverno.io/reason: "<justification>"    # REQUIRED
    policies.kyverno.io/reviewed-by: "<gh-handle>"  # REQUIRED
spec:
  exceptions:
    - policyName: <cluster-policy-name>
      ruleNames:
        - <rule-name-inside-policy>
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - <target-namespace>
          names:
            - "<pod-name-prefix>-*"
```

### Applying and verifying

```bash
# Apply the exception
kubectl apply -f policies/kyverno/policy-exceptions/<policy-name>-<reason>.yaml

# Confirm it was created
kubectl get policyexception -n <namespace>

# Check for expiring exceptions (run periodically)
kubectl get policyexception -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.metadata.annotations.policies\.kyverno\.io/expiry}{"\n"}{end}'
```

See `policies/kyverno/policy-exceptions/README.md` for the full workflow and
`policies/kyverno/policy-exceptions/example-exception.yaml.disabled` for a
complete template.

---

## Kyverno Prometheus Metrics

Kyverno exposes Prometheus metrics on port `8000` (path `/metrics`) of the
Kyverno controller pod. These metrics are useful for understanding admission
policy impact and latency before and after a promotion to Enforce.

### Key metrics

| Metric | Type | Description |
|--------|------|-------------|
| `kyverno_admission_requests_total` | Counter | Total admission requests processed, labelled by `resource_kind`, `resource_namespace`, `admission_request_type` (mutate/validate), `policy_name`, `rule_name`, `resource_request_operation`, `policy_response` (pass/fail/error/skip) |
| `kyverno_admission_review_duration_seconds` | Histogram | Latency of each admission review, labelled by `resource_kind`, `policy_response`, `policy_name` |
| `kyverno_policy_results_total` | Counter | Total policy rule results, labelled by `policy_type`, `policy_name`, `rule_name`, `resource_kind`, `resource_namespace`, `result` (pass/fail/warn/error/skip) |
| `kyverno_policy_execution_duration_seconds` | Histogram | Time spent executing each policy rule |
| `kyverno_controller_reconcile_total` | Counter | Controller reconcile loop counts — useful for spotting policy controller health issues |

### Useful PromQL queries

```promql
# Rate of FAIL results per policy (over the last 5 minutes)
rate(kyverno_policy_results_total{result="fail"}[5m])

# Fail rate by namespace
sum by (resource_namespace) (
  rate(kyverno_policy_results_total{result="fail"}[5m])
)

# Admission review P99 latency by policy name
histogram_quantile(0.99,
  rate(kyverno_admission_review_duration_seconds_bucket[5m])
)

# Total admission requests blocked (Enforce mode) in the last hour
increase(kyverno_admission_requests_total{policy_response="fail"}[1h])

# Policies with the most violations (top 5)
topk(5, sum by (policy_name) (
  rate(kyverno_policy_results_total{result="fail"}[1h])
))
```

### Scraping config (Prometheus / ServiceMonitor)

```yaml
# Add to your Prometheus scrape config or ServiceMonitor:
- job_name: kyverno
  static_configs:
    - targets: ['kyverno-svc-metrics.kyverno.svc.cluster.local:8000']
```

Or, if using the Prometheus Operator:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kyverno
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kyverno
  namespaceSelector:
    matchNames: [kyverno]
  endpoints:
    - port: metrics
      interval: 30s
```

---

## Policy State and Planned Promotion Dates

| Policy | Current Mode | Introduced | Planned Enforce Date | Notes |
|--------|-------------|-----------|----------------------|-------|
| `disallow-latest-tag` | **Enforce** | Build 016 | N/A — always Enforce | Safe from day 1; CI always tags production images |
| `require-resource-limits` | **Enforce** | Build 016 (Audit) → Build 021 (Enforce) | Promoted | Zero violations during soak |
| `require-labels` | **Enforce** | Build 016 (Audit) → Build 021 (Enforce) | Promoted | Zero violations during soak |
| `require-readonly-rootfs` | **Enforce** | Build 016 (Audit) → Build 021 (Enforce) | Promoted | Zero violations during soak |
| `disallow-host-namespaces` | **Enforce** | Build 021 | N/A — Enforce from day 1 | New hardening; no existing workloads use host namespaces |
| `disallow-privileged-containers` | **Enforce** | Build 021 | N/A — Enforce from day 1 | New hardening; no existing workloads run privileged |
| `disallow-capabilities` | **Enforce** | Build 021 | N/A — Enforce from day 1 | New hardening; blocked cap set: NET_ADMIN, SYS_ADMIN, SYS_PTRACE, SYS_MODULE, NET_RAW |
| `verify-image-signatures` | **Audit** | Build 019 (policy) / Build 021 (tightened) | TBD — after ≥ 7 days clean Audit | See policy file header for full checklist |
| `require-pod-probes` | **Audit** | Build 021 | 2026-05-14 (est.) | New policy — soak first |

---

## Further Reading

- [Kyverno PolicyReport docs](https://kyverno.io/docs/policy-reports/)
- [Kyverno PolicyException docs](https://kyverno.io/docs/writing-policies/exceptions/)
- [Kyverno Metrics reference](https://kyverno.io/docs/monitoring/reportsmetrics/)
- Policy files: `policies/kyverno/`
- Exception templates: `policies/kyverno/policy-exceptions/`
