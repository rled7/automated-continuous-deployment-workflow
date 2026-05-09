#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# production-checklist.sh — verify the 5 production-readiness items are done.
#
# Items 1, 2, 3 are auto-checkable from the repo. Items 4 and 5 require
# cluster + GitHub access and are reported as "manual" with the verification
# command printed.
#
# Exit code: 0 if all auto-checks pass, 1 if any fail.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
MANUAL=0

ok()     { echo -e "  \033[32m✓\033[0m $*"; PASS=$((PASS+1)); }
fail()   { echo -e "  \033[31m✗\033[0m $*"; FAIL=$((FAIL+1)); }
manual() { echo -e "  \033[33m?\033[0m $*"; MANUAL=$((MANUAL+1)); }
section(){ echo -e "\n\033[1m▸ $*\033[0m"; }

# ─── 1. Real domain + Let's Encrypt prod issuer ──────────────────────────────
section "1. Domain + ClusterIssuer"
if grep -q '127\.0\.0\.1\.nip\.io' k8s/overlays/production/ingress-patch.yaml 2>/dev/null; then
    fail "Production Ingress still uses nip.io placeholder — replace with real domain"
elif grep -q 'yourdomain' k8s/overlays/production/ingress-patch.yaml 2>/dev/null; then
    fail "Production Ingress still uses 'yourdomain' placeholder"
else
    ok "Production Ingress hostname customised"
fi
if grep -q 'selfsigned-issuer' k8s/overlays/production/ingress-patch.yaml 2>/dev/null; then
    fail "Production Ingress still references selfsigned-issuer (use letsencrypt-prod)"
else
    ok "Production cluster-issuer is not selfsigned"
fi

# ─── 2. Real registry + signed agent image ──────────────────────────────────
section "2. Jenkins agent image reference"
if grep -q 'YOUR_ORG' docker/jenkins/jenkins.yaml 2>/dev/null; then
    fail "Jenkins agent image still references YOUR_ORG placeholder"
else
    ok "Jenkins agent image has a real registry"
fi
if grep -q ':latest"' docker/jenkins/jenkins.yaml 2>/dev/null \
   && grep -q 'jenkins-cicd-agent' docker/jenkins/jenkins.yaml; then
    fail "Jenkins agent image is pinned to :latest — use an immutable tag"
else
    ok "Jenkins agent image is not :latest"
fi

# ─── 3. Sealed secret placeholders ──────────────────────────────────────────
section "3. REPLACE_ME placeholders"
PLACEHOLDER_FILES=$(grep -rl 'REPLACE_ME' \
    argocd/bootstrap/apps/kube-prometheus-stack.yaml \
    argocd/bootstrap/apps/dex.yaml \
    argocd/bootstrap/apps/oauth2-proxy.yaml 2>/dev/null || true)
if [ -n "$PLACEHOLDER_FILES" ]; then
    fail "REPLACE_ME placeholders still present in:"
    echo "$PLACEHOLDER_FILES" | sed 's/^/      /'
    echo "      → swap for SealedSecret references; see docs/production-deployment.md §3"
else
    ok "No REPLACE_ME placeholders in alertmanager/dex/oauth2-proxy chart values"
fi

# ─── 4. Branch protection (manual — needs gh + auth) ─────────────────────────
section "4. GitHub branch protection (manual check)"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')
    if [ -n "$REPO" ]; then
        if gh api "/repos/$REPO/branches/main/protection" >/dev/null 2>&1; then
            ok "main has branch protection enabled (run gh api ... for details)"
        else
            fail "main has NO branch protection — run scripts/setup-branch-protection.sh"
        fi
    else
        manual "gh detected but no repo context. Run from inside a clone."
    fi
else
    manual "gh CLI not installed/authenticated; verify manually:  ./scripts/setup-branch-protection.sh"
fi

# ─── 5. Kyverno verify-image-signatures policy mode (manual) ────────────────
section "5. verify-image-signatures policy mode"
if grep -q 'validationFailureAction: Audit' policies/kyverno/verify-image-signatures.yaml 2>/dev/null; then
    manual "Policy is currently Audit (intentional during soak). After ≥7 days of clean policyreports,"
    manual "  promote: sed -i 's/validationFailureAction: Audit/validationFailureAction: Enforce/' policies/kyverno/verify-image-signatures.yaml"
elif grep -q 'validationFailureAction: Enforce' policies/kyverno/verify-image-signatures.yaml 2>/dev/null; then
    ok "Policy is Enforce — admission rejects unsigned images"
else
    fail "Could not parse validationFailureAction in verify-image-signatures.yaml"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "\033[1mProduction-readiness:\033[0m  \033[32m${PASS} pass\033[0m  \033[31m${FAIL} fail\033[0m  \033[33m${MANUAL} manual\033[0m"
[ "$FAIL" -eq 0 ]
