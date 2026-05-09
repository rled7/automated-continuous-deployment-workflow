#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# benchmark-pipeline.sh — Time every CI-equivalent step on the local machine.
#
# This is purely for development insight: "is the build slow because of npm ci,
# tests, or the docker layer?" It does NOT hit the cluster, does NOT push, does
# NOT run as part of any Jenkins/GH-Actions stage.
#
# Run:
#   make bench-pipeline                                  # human-readable table
#   make bench-pipeline ARGS=--json                      # JSON for diffing
#   ./scripts/benchmark-pipeline.sh --compare baseline   # diff vs benchmarks/baseline.json
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

JSON_OUT=0
COMPARE=""
SKIP_DOCKER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)        JSON_OUT=1; shift;;
    --compare)     COMPARE="$2"; shift 2;;
    --no-docker)   SKIP_DOCKER=1; shift;;
    -h|--help)
      echo "Usage: $0 [--json] [--compare baseline] [--no-docker]"
      exit 0;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

declare -a NAMES TIMES_MS

now_ms() { date +%s%3N; }

step() {
  local name="$1"; shift
  local start; start=$(now_ms)
  "$@" >/dev/null 2>&1
  local rc=$?
  local end; end=$(now_ms)
  NAMES+=("$name")
  TIMES_MS+=($((end - start)))
  [[ $JSON_OUT -eq 0 ]] && printf "  %-26s  %8dms  %s\n" "$name" "$((end - start))" "$([ $rc -eq 0 ] && echo ✓ || echo ⚠)"
}

[[ $JSON_OUT -eq 0 ]] && echo "▸ Pipeline benchmark"

# ─── App ─────────────────────────────────────────────────────────────────────
if [[ -d app/node_modules ]]; then
  step "lint"               bash -c "cd app && npm run lint"
  step "build"              bash -c "cd app && npm run build"
  step "test:unit"          bash -c "cd app && npm run test:unit"
  step "test:integration"   bash -c "cd app && npm run test:integration"
else
  [[ $JSON_OUT -eq 0 ]] && echo "  (skipping app steps — run 'cd app && npm install' first)"
fi

# ─── Kustomize ───────────────────────────────────────────────────────────────
if command -v kubectl >/dev/null 2>&1; then
  step "kustomize:production" bash -c "kubectl kustomize k8s/overlays/production"
  step "kustomize:staging"    bash -c "kubectl kustomize k8s/overlays/staging"
elif command -v kustomize >/dev/null 2>&1; then
  step "kustomize:production" bash -c "kustomize build k8s/overlays/production"
  step "kustomize:staging"    bash -c "kustomize build k8s/overlays/staging"
fi

# ─── kubeconform ─────────────────────────────────────────────────────────────
if command -v kubeconform >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  step "kubeconform" bash -c "for o in k8s/overlays/*/; do kubectl kustomize \"\$o\" | kubeconform -strict -ignore-missing-schemas -; done"
fi

# ─── Repo sanity ─────────────────────────────────────────────────────────────
if [[ -x scripts/check-repo.sh ]]; then
  step "check-repo" bash scripts/check-repo.sh
fi

# ─── Docker (slow — opt-out flag) ────────────────────────────────────────────
if [[ $SKIP_DOCKER -eq 0 ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  step "docker:build" bash -c "docker build -t my-app:bench -f docker/Dockerfile ."
fi

TOTAL=0
for t in "${TIMES_MS[@]}"; do TOTAL=$((TOTAL + t)); done

# ─── Output ──────────────────────────────────────────────────────────────────
if [[ $JSON_OUT -eq 1 ]]; then
  printf '{"timestamp":"%s","results":[' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for i in "${!NAMES[@]}"; do
    [[ $i -gt 0 ]] && printf ','
    printf '{"step":"%s","duration_ms":%d}' "${NAMES[$i]}" "${TIMES_MS[$i]}"
  done
  printf '],"total_ms":%d}\n' "$TOTAL"
else
  printf "\n  %-26s  %8s\n" "──────" "────"
  printf "  %-26s  %8sms\n" "TOTAL" "$TOTAL"
  if [[ -n "$COMPARE" && -f "$COMPARE" ]]; then
    echo ""
    echo "▸ vs $COMPARE"
    for i in "${!NAMES[@]}"; do
      base=$(grep -oE "\"step\":\"${NAMES[$i]}\",\"duration_ms\":[0-9]+" "$COMPARE" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || echo '')
      if [[ -n "$base" && "$base" -gt 0 ]]; then
        delta=$(( ((TIMES_MS[$i] - base) * 100) / base ))
        sign=$([ $delta -gt 0 ] && echo "+" || echo "")
        printf "  %-26s  %8dms  (was %dms, %s%d%%)\n" "${NAMES[$i]}" "${TIMES_MS[$i]}" "$base" "$sign" "$delta"
      fi
    done
  fi
fi
