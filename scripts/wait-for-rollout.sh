#!/usr/bin/env bash
# Wait for an Argo Rollout to finish rolling out — the Rollout equivalent of
# `kubectl rollout status deployment/...`, without needing the
# kubectl-argo-rollouts plugin on the Jenkins agent.
#
# Usage: wait-for-rollout.sh NAMESPACE NAME [TIMEOUT_SECONDS]
# Exits 0 once the controller has observed the latest spec and reports
# Healthy; 1 if the Rollout is Degraded or the timeout passes.
set -euo pipefail

ns=$1
name=$2
timeout=${3:-900}
deadline=$(( $(date +%s) + timeout ))

while [ "$(date +%s)" -lt "$deadline" ]; do
  read -r generation observed phase < <(kubectl get rollout "$name" --namespace="$ns" \
    -o jsonpath='{.metadata.generation} {.status.observedGeneration} {.status.phase}{"\n"}')
  echo "rollout/$name: phase=${phase:-unknown} observedGeneration=${observed:-none}/${generation}"
  if [ "${observed:-}" = "$generation" ]; then
    case "${phase:-}" in
      Healthy) echo "rollout/$name is healthy"; exit 0 ;;
      Degraded) echo "rollout/$name is degraded" >&2; exit 1 ;;
    esac
  fi
  sleep 10
done

echo "timed out after ${timeout}s waiting for rollout/$name" >&2
exit 1
