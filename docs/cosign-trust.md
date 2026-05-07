# Cosign Keyless Signing — Trust Infrastructure

This document explains how the `my-app` pipeline uses cosign keyless signing to
establish a verifiable supply-chain trust path from CI build to production cluster.

---

## What is keyless cosign signing?

Keyless signing removes the need to manage long-lived private keys. Instead, it
relies on short-lived X.509 certificates issued by **Fulcio**, Sigstore's
certificate authority, and an append-only transparency log called **Rekor**.

The signing flow is:

1. The CI runner authenticates to an OIDC provider (e.g. GitHub Actions OIDC,
   Keycloak, or a cloud-provider IAM endpoint) and receives a short-lived ID token.
2. `cosign sign` presents that token to **Fulcio** (`fulcio.sigstore.dev`). Fulcio
   validates the token, then issues an ephemeral X.509 certificate whose Subject
   Alternative Name (SAN) encodes the OIDC subject claim (e.g. the GitHub Actions
   workflow URI or a Kubernetes service account).
3. cosign creates a signature over the OCI image manifest digest using the ephemeral
   private key, then immediately discards the key.
4. The signature, certificate, and an inclusion proof are uploaded to **Rekor**
   (`rekor.sigstore.dev`), the public immutable transparency log. Rekor provides a
   timestamped, tamper-evident record of every signing event.
5. The ephemeral certificate expires within 10 minutes. All that persists is the
   record in Rekor and the cosign bundle attached to the OCI image (stored as an
   OCI artifact alongside the image in the registry).

---

## The two trust paths

### Path 1 — Keyless (public Sigstore) — used in this pipeline

| Component | Role |
|-----------|------|
| Fulcio (`fulcio.sigstore.dev`) | Issues ephemeral signing certs bound to the OIDC identity |
| Rekor (`rekor.sigstore.dev`) | Immutable transparency log; stores signatures + inclusion proofs |
| OIDC provider | Authenticates the builder identity (GitHub OIDC, Keycloak, cloud IAM) |
| Kyverno / cosign verify | Validates cert chain against bundled Fulcio root CA + Rekor inclusion proof |

Verification succeeds only when:
- The signature is present in Rekor (inclusion proof valid).
- The Fulcio-issued certificate chains to the trusted Fulcio root CA.
- The certificate Subject matches the configured `subject` (e.g. the GitHub workflow URI).
- The certificate Issuer matches the configured `issuer` (e.g. `https://token.actions.githubusercontent.com`).

### Path 2 — Key-based (your own KMS)

In this model the pipeline signs with a long-lived private key stored in a KMS.
Verification uses the corresponding public key.

```
# Sign with a GCP KMS key:
cosign sign --key gcpkms://projects/MY_PROJECT/locations/global/keyRings/MY_RING/cryptoKeys/MY_KEY IMAGE

# Sign with an AWS KMS key:
cosign sign --key awskms:///arn:aws:kms:us-east-1:123456789012:key/MY_KEY_ID IMAGE

# Sign with an Azure Key Vault key:
cosign sign --key azurekms://MY_VAULT.vault.azure.net/MY_KEY IMAGE
```

Verification:
```
# GCP
cosign verify --key gcpkms://projects/MY_PROJECT/locations/global/keyRings/MY_RING/cryptoKeys/MY_KEY IMAGE

# AWS
cosign verify --key awskms:///arn:aws:kms:us-east-1:123456789012:key/MY_KEY_ID IMAGE

# Azure
cosign verify --key azurekms://MY_VAULT.vault.azure.net/MY_KEY IMAGE
```

---

## Why this pipeline chose keyless

| Concern | Keyless | Key-based |
|---------|---------|-----------|
| Key management | None — ephemeral certs expire in ≤ 10 min | Must rotate, backup, and secure KMS keys |
| Audit trail | Every signature event recorded in Rekor (tamper-evident) | Only what your KMS audit log captures |
| Key compromise blast radius | Zero — no reusable key exists | Attacker with key can sign arbitrary images |
| Public verifiability | Anyone can verify via Rekor without shared secrets | Requires access to the public key |
| Works with GitHub Actions OIDC | Native — GitHub Actions exposes OIDC tokens out of the box | Requires storing KMS credentials as GitHub secrets |
| Operational overhead | Low | Medium–high (KMS provisioning, IAM, rotation) |

For this pipeline the audit-trail and zero-key-management properties outweigh the
dependency on Sigstore's public infrastructure. For air-gapped or highly regulated
environments, the key-based path (or a self-hosted Sigstore instance) is more
appropriate.

---

## Verifying a signature locally

```bash
cosign verify \
  --certificate-identity 'https://github.com/rled7/automated-continuous-deployment-workflow/.github/workflows/*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/YOUR_ORG/my-app:<TAG>
```

Replace `<TAG>` with the specific image tag or digest (`@sha256:...`). The output
lists each matching signature with its Rekor log ID, certificate SAN, and timestamp.

For a Jenkins OIDC signer, the subject is determined by the OIDC provider:
- **GitHub OIDC**: `https://github.com/<ORG>/<REPO>/.github/workflows/<WORKFLOW>.yml@refs/heads/<BRANCH>`
- **Keycloak**: typically `<client_id>` or a service account name — inspect `sub` in the decoded token.
- **Kubernetes OIDC / Workload Identity**: `system:serviceaccount:<namespace>:<sa-name>` (depends on provider).

---

## How to migrate to key-based signing later

If requirements change (e.g. air-gap, compliance audit), migration to KMS-backed
cosign is straightforward:

### 1. Provision a KMS key

```bash
# GCP — create a ECDSA P-256 signing key
gcloud kms keyrings create cicd-signing --location global
gcloud kms keys create cosign-key \
  --keyring cicd-signing \
  --location global \
  --purpose asymmetric-signing \
  --default-algorithm ec-sign-p256-sha256

# AWS — create a KMS key (asymmetric, SIGN_VERIFY)
aws kms create-key \
  --key-usage SIGN_VERIFY \
  --key-spec ECC_NIST_P256 \
  --description "cosign signing key"

# Azure — create a key in Key Vault
az keyvault key create \
  --vault-name MY_VAULT \
  --name cosign-key \
  --kty EC \
  --curve P-256 \
  --ops sign verify
```

### 2. Update the Jenkinsfile sign step

Replace the keyless `cosign sign` call with the KMS-backed equivalent:

```groovy
// GCP KMS
sh "cosign sign --key gcpkms://projects/${GCP_PROJECT}/locations/global/keyRings/cicd-signing/cryptoKeys/cosign-key ${FULL_IMAGE}"

// AWS KMS (key ARN from environment)
sh "cosign sign --key awskms:///${KMS_KEY_ARN} ${FULL_IMAGE}"

// Azure Key Vault
sh "cosign sign --key azurekms://${AZURE_VAULT_NAME}.vault.azure.net/cosign-key ${FULL_IMAGE}"
```

### 3. Export the public key and update Kyverno

```bash
# GCP
cosign public-key --key gcpkms://... > cosign.pub

# AWS
cosign public-key --key awskms:///... > cosign.pub

# Azure
cosign public-key --key azurekms://... > cosign.pub
```

Store `cosign.pub` in the repo and update the Kyverno policy:

```yaml
verifyImages:
  - imageReferences:
      - "ghcr.io/YOUR_ORG/my-app:*"
    attestors:
      - entries:
          - keys:
              publicKeys: |-
                -----BEGIN PUBLIC KEY-----
                <contents of cosign.pub>
                -----END PUBLIC KEY-----
```

Remove the `keyless:` block and the `issuer`/`subject` fields — they are not used
for key-based verification.

---

## Related files

- `Jenkinsfile` — `cosign sign` + `cosign attest` steps (Docker Build & Push stage, Scan SBOM stage)
- `policies/kyverno/verify-image-signatures.yaml` — admission-time verification policy (Audit; Enforce in Build 021)
- `docker/jenkins-agent/Dockerfile` — installs cosign + grype on the agent image
