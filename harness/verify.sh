#!/usr/bin/env bash
# Local verification harness: runs the checks a human would do before trusting
# a change to this repo, without real cloud accounts or clusters.
#
#   harness/verify.sh                 # default stages
#   harness/verify.sh static pod      # only these stages
#   harness/verify.sh --list
#
# Results: harness/.results/results.json (machine-readable, one entry per
# stage with its steps) and harness/.results/logs/<stage>.log.
# Exit code: 0 if every stage passed or was skipped, 1 otherwise.

source "$(dirname "$0")/lib/common.sh"
# Fix the image tag for the whole run, so a commit made mid-run doesn't send
# later stages looking for a tag the image stage never built.
export DEPLOY_IMAGE

DEFAULT_STAGES=(static app image pod cluster-sim terraform)
# Opt-in: needs a host where kind can run (your machine, GitHub Actions).
OPTIONAL_STAGES=(cluster-real)

describe() {
  case $1 in
    static)       echo "Render overlays; schema, sanity and Kyverno policy checks" ;;
    app)          echo "npm ci, lint and unit tests in app/" ;;
    image)        echo "Build the production Docker image" ;;
    pod)          echo "Run the staging Deployment with podman kube play + Postgres/Redis; migrations, probes, smoke tests" ;;
    cluster-sim)  echo "Apply every overlay to a KWOK simulated cluster (real API server, fake nodes)" ;;
    terraform)    echo "fmt/validate/test/apply/drift/destroy each Terraform dir against Floci (local AWS)" ;;
    cluster-real) echo "Deploy staging to a real kind cluster and run smoke tests" ;;
  esac
}

if [ "${1:-}" = "--list" ]; then
  for s in "${DEFAULT_STAGES[@]}"; do printf '  %-13s %s\n' "$s" "$(describe "$s")"; done
  for s in "${OPTIONAL_STAGES[@]}"; do printf '  %-13s %s (opt-in)\n' "$s" "$(describe "$s")"; done
  exit 0
fi

STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=("${DEFAULT_STAGES[@]}")

LOG_DIR="$RESULTS_DIR/logs"
rm -rf "$LOG_DIR" "$RESULTS_DIR/steps" && mkdir -p "$LOG_DIR" "$RESULTS_DIR/steps"
STAGE_RESULTS="$RESULTS_DIR/stages.jsonl"
: > "$STAGE_RESULTS"

overall=0
for stage in "${STAGES[@]}"; do
  script="$HARNESS_DIR/stages/$stage.sh"
  [ -f "$script" ] || { log "unknown stage: $stage (see --list)"; exit 2; }

  log "━━ stage: $stage — $(describe "$stage")"
  start=$(date +%s)
  steps_file="$RESULTS_DIR/steps/$stage.jsonl"; : > "$steps_file"
  skip_file="$RESULTS_DIR/steps/$stage.skip"; rm -f "$skip_file"
  STEPS_FILE="$steps_file" STAGE_SKIP_FILE="$skip_file" bash "$script" > "$LOG_DIR/$stage.log" 2>&1
  rc=$?

  case $rc in
    0) status=pass ;;
    3) status=skip ;;
    *) status=fail; overall=1 ;;
  esac
  jq -nc --arg stage "$stage" --arg status "$status" --argjson rc "$rc" \
    --argjson secs "$(( $(date +%s) - start ))" \
    --arg log "logs/$stage.log" --arg reason "$(cat "$skip_file" 2>/dev/null)" \
    --slurpfile steps "$steps_file" \
    '{stage:$stage,status:$status,exit_code:$rc,seconds:$secs,log:$log,steps:$steps}
     + (if $reason != "" then {skip_reason:$reason} else {} end)' >> "$STAGE_RESULTS"
  log "   → $status (${rc}) in $(( $(date +%s) - start ))s; log: $LOG_DIR/$stage.log"
  if [ "$status" = fail ]; then
    jq -r '"     failed step: \(.name)"' < <(jq -c 'select(.status=="fail")' "$steps_file") >&2
  fi
done

jq -s --arg commit "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)" \
  '{commit:$commit, passed:(all(.[]; .status!="fail")), stages:.}' \
  "$STAGE_RESULTS" > "$RESULTS_DIR/results.json"

echo
jq -r '.stages[] | "\(.status | ascii_upcase)  \(.stage)  (\(.seconds)s)"' "$RESULTS_DIR/results.json"
echo "results: $RESULTS_DIR/results.json"
exit $overall
