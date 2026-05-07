# Disaster Recovery Runbook

**Last updated:** Build 022  
**Owner:** Platform / SRE team  
**Related docs:** `docs/runbook.md` (alert response), `docs/secrets.md` (credential rotation)

---

## Recovery Objectives

| Metric | Target | Rationale |
|--------|--------|-----------|
| **RPO** (Recovery Point Objective) | 24 hours | Daily Velero backups at 02:00 UTC. Worst case: lose up to 24 h of data. For lower RPO, add hourly backups or switch to DB-native WAL streaming. |
| **RTO** (Recovery Time Objective) — app only | 1 hour | Restore a Velero namespace backup + redeploy via Argo CD. |
| **RTO** — full cluster | 4 hours | Bootstrap new cluster, reinstall Argo CD, sync all apps, restore Velero backups. |

---

## Backup Verification

Velero backups are scheduled by `monitoring/velero/schedules.yaml` and stored in MinIO
(local) or the cloud object store (production). Check backup health regularly:

```bash
# List recent backups and their status
kubectl get backups -n velero

# Inspect a specific backup
kubectl describe backup <BACKUP_NAME> -n velero

# Expected: Phase: Completed, no warnings about skipped volumes
```

**Weekly check (add to on-call rotation):**

```bash
kubectl get backups -n velero --sort-by=.metadata.creationTimestamp | tail -10
# Confirm: at least one Completed backup in the last 24 h for production
# Confirm: at least one Completed backup in the last 7 days (weekly-cluster)
```

If a backup shows `Phase: Failed` or `Phase: PartiallyFailed`:
1. `kubectl describe backup <NAME> -n velero` to read the failure reason.
2. Common causes: MinIO unreachable, BSL misconfigured, volume snapshot timeout.
3. Fix the underlying issue, then trigger a manual backup:
   ```bash
   velero backup create manual-$(date +%Y%m%d) --include-namespaces production
   ```

---

## Quarterly DR Drill Checklist

Run this drill every quarter on a **non-production cluster** (or a fresh kind cluster).
Document results in the team wiki or a dated `chaos-diary` entry.

### Before the drill

- [ ] Identify the backup to restore from: `kubectl get backups -n velero`
- [ ] Provision a fresh kind cluster (or borrow a non-production cluster)
- [ ] Install Argo CD on the new cluster
- [ ] Point Argo CD at this Git repo (same branch)
- [ ] Install Velero + MinIO on the new cluster (sync `platform` project)
- [ ] Copy the MinIO bucket contents from the original cluster to the new one
      (or point at the same MinIO / S3 endpoint if network-accessible)

### Drill steps

1. **Restore from backup**
   ```bash
   # List available backups
   velero backup get

   # Restore the most recent production backup
   velero restore create --from-backup <BACKUP_NAME> \
     --include-namespaces production
   ```

2. **Wait for restore to complete**
   ```bash
   velero restore get
   # Phase should transition: New → InProgress → Completed
   kubectl get pods -n production -w
   ```

3. **Verify app is running**
   ```bash
   # Check pod health
   kubectl get pods -n production
   # Check readiness endpoint
   curl -s https://<CLUSTER_INGRESS>/health/ready
   # Expect: {"status":"ok"} with HTTP 200
   ```

4. **Verify data integrity**
   ```bash
   # Sample queries against the restored database
   # (Adjust connection details for the restored cluster)
   kubectl exec -it <DB_POD> -n production -- \
     psql -U postgres -c "SELECT count(*) FROM items;"
   # Compare row count against known-good value from pre-backup
   ```

5. **Document results**
   - Time to restore (step 1 → step 3 complete)
   - Any errors encountered
   - Row counts match expected values? (Y/N)
   - Action items for next drill

### After the drill

- [ ] Tear down the test cluster
- [ ] File issues for any gaps found
- [ ] Update this runbook if steps changed

---

## Disaster Scenarios and Playbooks

### Scenario 1 — Pod Failures

**Symptoms:** One or more pods crash-loop or are evicted.

**Response:** No manual action needed. Kubernetes restarts pods automatically.
Argo Rollouts detects instability and pauses active rollouts. Monitor:

```bash
kubectl get pods -n production -w
kubectl describe rollout my-app -n production
```

If pods do not recover within 5 minutes, escalate to the node/resource level.

---

### Scenario 2 — Single-AZ Outage (cloud only)

**Symptoms:** All pods on nodes in one availability zone become unavailable.

**Response:** `topologySpreadConstraints` in the Deployment spec distributes pods
across AZs. Kubernetes reschedules evicted pods to healthy AZs automatically.

**Prerequisite:** The cluster must have nodes in multiple AZs and the Deployment
must have `topologySpreadConstraints` configured. Verify:

```bash
kubectl get nodes --label-columns topology.kubernetes.io/zone
kubectl get deployment my-app -n production -o yaml | grep -A5 topologySpreadConstraints
```

**Note:** This is only applicable to cloud clusters. kind clusters are single-node
by default and do not support AZ distribution.

---

### Scenario 3 — Region Outage

**Known limitation:** This deployment is a single-cluster setup. A full region
outage takes down the entire cluster. Multi-region active-active or active-passive
failover is out of scope for this configuration.

**Mitigation:** Velero backups are stored in MinIO. If MinIO is also in the same
region, backups are lost too. For real disaster tolerance:
- Replicate MinIO buckets cross-region (or use S3 with cross-region replication).
- Consider a standby cluster in a second region with Argo CD pointing at the same
  Git repo.

Document this as a known gap and revisit when the service reaches higher SLO tiers.

---

### Scenario 4 — Database Corruption

**Symptoms:** Application logs show data integrity errors; queries return unexpected
results; DB health check fails.

**Immediate actions:**
1. Scale the app to zero replicas to prevent further writes:
   ```bash
   kubectl scale deployment my-app --replicas=0 -n production
   ```
2. Take a snapshot of the corrupted state for forensics:
   ```bash
   velero backup create corruption-snapshot-$(date +%Y%m%d%H%M) \
     --include-namespaces production
   ```
3. Restore from the last known-good Velero backup:
   ```bash
   velero restore create --from-backup <LAST_GOOD_BACKUP> \
     --include-namespaces production
   ```
4. Alternatively, restore from a DB-native backup (pg_dump / managed DB snapshot).
5. After restore, run data integrity checks before scaling the app back up.

---

### Scenario 5 — Full Cluster Destruction

**Symptoms:** The entire Kubernetes cluster is gone (node failure, cloud incident,
accidental `terraform destroy`, etc.).

**Recovery steps:**

1. Provision a new cluster (kind for local, managed Kubernetes for cloud).
2. Install Argo CD:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```
3. Apply the Argo CD bootstrap App-of-Apps:
   ```bash
   kubectl apply -f argocd/bootstrap/root-app.yaml
   ```
4. Wait for platform apps to sync (sealed-secrets, cert-manager, ingress-nginx,
   Velero, MinIO in order per sync wave).
5. Restore from Velero backup:
   ```bash
   velero backup get
   velero restore create --from-backup weekly-cluster-<DATE>
   ```
6. Verify all namespaces, deployments, and data are restored.
7. Update DNS / load balancer to point at the new cluster.

**RTO target:** 4 hours for a practiced team following this runbook.

---

### Scenario 6 — Compromised SealedSecret Master Key

**Symptoms:** Evidence that the cluster's SealedSecret controller private key has
been leaked (e.g., found in a public repo, confirmed in a security audit).

**Immediate actions:**

1. **Revoke the compromised key** — the Sealed Secrets controller supports key
   rotation. Fetch the current key name:
   ```bash
   kubectl get secrets -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key
   ```
2. **Generate a new key** — the controller creates a new key automatically when
   the old one is rotated out. Alternatively, force rotation:
   ```bash
   # Label the old key as compromised (controller stops using it for decryption
   # after a configurable TTL)
   kubectl label secret <KEY_SECRET_NAME> -n kube-system \
     sealedsecrets.bitnami.com/sealed-secrets-key=compromised
   ```
3. **Re-seal all secrets** — every `SealedSecret` in the repo must be re-encrypted
   with the new key:
   ```bash
   # For each secret, obtain the plaintext value and re-seal:
   kubeseal --fetch-cert > new-pub-key.pem
   kubectl get secret <SECRET_NAME> -n <NAMESPACE> -o yaml | \
     kubeseal --cert new-pub-key.pem -o yaml > sealed-<SECRET_NAME>.yaml
   # Commit the re-sealed files and push
   ```
4. **Key backup loss scenario** — if the private key backup is also lost:
   - The controller cannot decrypt existing SealedSecrets.
   - All secrets must be restored from their original plaintext sources (password
     manager, team vault, etc.) and re-sealed with the new key.
   - This is a total secrets rotation event — treat as a P1 incident.
   - Rotate all downstream credentials (DB passwords, API keys, etc.) as a
     precaution since the key loss means the window of exposure is unknown.

**Prevention:** Back up the master key to a secrets manager (HashiCorp Vault,
AWS Secrets Manager, etc.) immediately after cluster creation. See `docs/secrets.md`.

---

## Contact and Escalation

| Severity | Action |
|----------|--------|
| Pods not recovering after 5 min | Page on-call SRE (`docs/oncall.md`) |
| Data loss suspected | Escalate to engineering lead + initiate incident process |
| Full cluster gone | Major incident — all hands; follow this runbook |
| Compromised credentials | Security incident — notify security team immediately |
