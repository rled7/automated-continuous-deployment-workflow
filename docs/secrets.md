# Secrets Management with Sealed Secrets

## Why Sealed Secrets?

Kubernetes `Secret` objects are **base64-encoded**, not encrypted — storing them in
git gives read access to anyone with repo access.  Three common alternatives:

| Approach | Pros | Cons |
|---|---|---|
| **Plain Secrets in git** | Simple | Plaintext in repo — never acceptable |
| **External Secrets Operator (ESO)** | Integrates with Vault, AWS SSM, GCP SM, etc. | Requires an external secret store; more moving parts |
| **Sealed Secrets** | Works offline; ciphertext safe in git; no external dependency | Per-cluster keys; must re-seal when migrating clusters |

**Sealed Secrets** is the right default for a self-hosted kind/bare-metal setup:
you get encrypted-at-rest-in-git secrets with no cloud account required.

## How it works

1. The **sealed-secrets controller** (installed by Argo CD in `kube-system`)
   generates an RSA key pair on first boot and stores it as a Kubernetes Secret.
2. You encrypt a plain Secret locally using `kubeseal` (which fetches the
   controller's public key) → produces a `SealedSecret` CRD.
3. You commit the `SealedSecret` YAML (it's safe — only the controller can
   decrypt it).
4. Argo CD syncs the `SealedSecret` to the cluster → the controller decrypts it
   → a plain `Secret` appears in the target namespace.

## Sealing a new secret

Use `scripts/seal-secret.sh` for generic key/value secrets:

```bash
# Seal and write output to k8s/secrets/
scripts/seal-secret.sh production my-app-secrets \
    db-host=mydb.prod.internal \
    db-password='p@$$w0rd!' \
  > k8s/secrets/my-app-secrets.yaml

# Commit the sealed output (plaintext is never stored)
git add k8s/secrets/my-app-secrets.yaml
git commit -m "chore: seal my-app-secrets for production"
```

For `docker-registry` typed secrets use `kubectl create secret docker-registry`
piped directly through `kubeseal`:

```bash
kubectl create secret docker-registry docker-registry-secret \
    --docker-server=ghcr.io \
    --docker-username=<user> \
    --docker-password=<token> \
    --namespace=production \
    --dry-run=client -o yaml \
  | kubeseal --format=yaml --controller-namespace=kube-system \
  > k8s/secrets/docker-registry-secret.yaml
```

## Secret rotation

1. Re-seal the new value with `seal-secret.sh` (or manually).
2. Overwrite the file in `k8s/secrets/`.
3. Commit and push.
4. Argo CD detects the diff and applies the new `SealedSecret`.
5. The controller decrypts → updates the plain `Secret` in-cluster.
6. Pods that reference the secret pick up the new value on their next
   restart (or immediately if using a projected volume with `optional: false`).

## Backing up the controller's private key

If the controller key is lost, **all sealed secrets become unrecoverable** — you
would need to re-seal every secret from scratch.  Back up the key immediately
after cluster creation:

```bash
# The key is stored as a Secret in kube-system.
# Its name follows the pattern sealed-secrets-<random>.
kubectl get secret -n kube-system \
    -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
    -o yaml > sealed-secrets-key-backup.yaml

# Store this file somewhere secure (password manager, encrypted S3 bucket, etc.)
# DO NOT commit it to git.
```

## Disaster recovery — restoring the key on a new cluster

If you must rebuild the cluster but have the backup:

```bash
# 1. Install the sealed-secrets controller (via Argo CD bootstrap or helm).
# 2. Before the controller generates a new key, restore the old one:
kubectl apply -f sealed-secrets-key-backup.yaml

# 3. Restart the controller so it picks up the restored key.
kubectl rollout restart deployment sealed-secrets-controller -n kube-system

# 4. Verify the controller is healthy, then sync Argo CD — all SealedSecrets
#    will decrypt correctly with the restored key.
```

## Template files

See `k8s/secrets/*.template.yaml` for placeholder manifests and
`k8s/secrets/README.md` for the full workflow.
