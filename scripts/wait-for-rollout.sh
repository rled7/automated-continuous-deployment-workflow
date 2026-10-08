#!/usr/bin/env bash
# Wait for an Argo Rollout to finish rolling out — the Rollout equivalent of
# `kubectl rollout status deployment/...`, without needing the
# kubectl-argo-rollouts plugin on the Jenkins agent.
#
# Usage: wait-for-rollout.sh NAMESPACE NAME [TIMEOUT_SECONDS]
# Exits 0 once the controller has observed the latest spec and reports
# Healthy; 1 if Argo aborted the rollout (e.g. a failed canary analysis), if
# it stays Degraded for three checks in a row, or if the timeout passes.
# A Degraded phase that clears on its own (a freshly created Rollout can
# briefly report one while the resources it references are still being
# created) is not a failure.
set -euo pipefail

ns=$1
name=$2
timeout=${3:-900}
deadline=$(( $(date +%s) + timeout ))
degraded_checks=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  IFS='|' read -r generation observed phase aborted message < <(kubectl get rollout "$name" --namespace="$ns" \
    -o jsonpath='{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.status.phase}{"|"}{.status.abort}{"|"}{.status.message}{"\n"}')
  echo "rollout/$name: phase=${phase:-unknown} observedGeneration=${observed:-none}/${generation}${message:+ ($message)}"
  if [ "${observed:-}" = "$generation" ]; then
    case "${phase:-}" in
      Healthy)
        echo "rollout/$name is healthy"; exit 0 ;;
      Degraded)
        if [ "${aborted:-}" = true ]; then
          echo "rollout/$name was aborted: ${message:-no message}" >&2; exit 1
        fi
        degraded_checks=$((degraded_checks + 1))
        if [ "$degraded_checks" -ge 3 ]; then
          echo "rollout/$name is degraded: ${message:-no message}" >&2; exit 1
        fi ;;
      *)
        degraded_checks=0 ;;
    esac
  fi
  sleep "${WAIT_FOR_ROLLOUT_INTERVAL:-10}"
done

echo "timed out after ${timeout}s waiting for rollout/$name" >&2
exit 1
