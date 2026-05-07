#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-repo.sh — Repo sanity check.
# Runs every static validation we have without touching network or the cluster.
# Useful pre-PR locally, and as a single-command fast feedback signal in CI.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
SKIP=0

ok()    { echo -e "  \033[32m✓\033[0m  $*"; PASS=$((PASS+1)); }
fail()  { echo -e "  \033[31m✗\033[0m  $*"; FAIL=$((FAIL+1)); }
skip()  { echo -e "  \033[33m·\033[0m  $* (skipped — tool not on PATH)"; SKIP=$((SKIP+1)); }
have()  { command -v "$1" >/dev/null 2>&1; }

section() { echo -e "\n\033[1m▸ $*\033[0m"; }

# ── App: lint + tests ─────────────────────────────────────────────────────────
section "App"
if have node && [ -d app/node_modules ]; then
    (cd app && npm run lint --silent 2>&1) >/dev/null && ok "ESLint" || fail "ESLint"
    (cd app && NODE_ENV=test NODE_OPTIONS=--experimental-vm-modules npx jest --silent --listTests 2>&1) >/dev/null \
        && ok "Jest test discovery" || fail "Jest test discovery"
else
    skip "ESLint / Jest (run 'cd app && npm install' first)"
fi

# ── Shell scripts: bash -n ───────────────────────────────────────────────────
section "Shell scripts"
for f in scripts/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null && ok "bash -n $f" || fail "bash -n $f"
done

# ── JS files outside app/: node --check ──────────────────────────────────────
section "JS syntax (root + tests/)"
if have node; then
    for f in commitlint.config.js tests/performance/compare-baseline.js; do
        [ -f "$f" ] || continue
        node --check "$f" 2>/dev/null && ok "node --check $f" || fail "node --check $f"
    done
else
    skip "node --check (node not on PATH)"
fi

# ── YAML: parse with python or yq ────────────────────────────────────────────
section "YAML syntax"
yaml_check() {
    if have yq; then
        yq eval-all '.' "$1" >/dev/null 2>&1
    elif have python3; then
        python3 -c "import sys, yaml; list(yaml.safe_load_all(open('$1')))" 2>/dev/null
    else
        return 2
    fi
}

YAML_CHECKED=0
while IFS= read -r -d '' f; do
    yaml_check "$f"
    rc=$?
    if [ $rc -eq 0 ]; then
        YAML_CHECKED=$((YAML_CHECKED+1))
    elif [ $rc -eq 2 ]; then
        skip "YAML parse (install yq or python3)"
        break
    else
        fail "YAML parse: $f"
    fi
done < <(find argocd k8s monitoring policies chaos .github -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
[ $YAML_CHECKED -gt 0 ] && ok "YAML parse ($YAML_CHECKED files)"

# ── Kustomize overlays render cleanly ───────────────────────────────────────
section "Kustomize"
if have kubectl; then
    for overlay in k8s/overlays/*/; do
        kubectl kustomize "$overlay" >/dev/null 2>&1 \
            && ok "kustomize $overlay" || fail "kustomize $overlay"
    done
elif have kustomize; then
    for overlay in k8s/overlays/*/; do
        kustomize build "$overlay" >/dev/null 2>&1 \
            && ok "kustomize $overlay" || fail "kustomize $overlay"
    done
else
    skip "kustomize (install kubectl or kustomize)"
fi

# ── kubeconform on rendered manifests ───────────────────────────────────────
section "Kubernetes manifest schema"
if have kubeconform && have kubectl; then
    for overlay in k8s/overlays/*/; do
        kubectl kustomize "$overlay" 2>/dev/null \
            | kubeconform -strict -summary -ignore-missing-schemas - >/dev/null 2>&1 \
            && ok "kubeconform $overlay" || fail "kubeconform $overlay"
    done
else
    skip "kubeconform"
fi

# ── Gitleaks ─────────────────────────────────────────────────────────────────
section "Secret scan"
if have gitleaks; then
    gitleaks detect --no-git --source . --redact --exit-code 1 >/dev/null 2>&1 \
        && ok "gitleaks (no findings)" || fail "gitleaks (findings — see .gitleaks.toml)"
else
    skip "gitleaks"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "\033[1mSummary:\033[0m  \033[32m${PASS} pass\033[0m  \033[31m${FAIL} fail\033[0m  \033[33m${SKIP} skipped\033[0m"
[ "$FAIL" -eq 0 ]
