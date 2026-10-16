#!/usr/bin/env bash
# The production path of the Jenkinsfile, on a real kind cluster running the
# Argo Rollouts controller:
#
#   1. a cluster deployed before the overlay fix, still running the stray base
#      Deployment next to the Rollout;
#   2. deployToKubernetes('production'): migrations, apply, wait for the
#      Rollout (scripts/wait-for-rollout.sh), remove the stray Deployment,
#      smoke tests through the Service;
#   3. Prometheus with the real my-app scrape job, and traffic through the
#      Service from a stand-in for the ingress controller;
#   4. a healthy release: the canary analysis must measure it on Prometheus
#      data and promote it;
#   5. a release whose GET /api/items fails: the analysis must fail it on the
#      measured 5xx rate, wait-for-rollout.sh must report it, and rollback()
#      must put the healthy release back.
#
# The canary's pauses (2 min each in the overlay) are cut to CANARY_PAUSE
# (default 30s) in the harness's copies of the releases: long enough for
# Prometheus to have the new pods' samples, short enough for CI.
#
# Needs a host where kind works (your machine, GitHub Actions). KEEP=1 leaves
# the cluster up.
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"
source "$HARNESS_DIR/lib/kind.sh"

CLUSTER=harness-prod
NS=production
WAIT_FOR_ROLLOUT="$REPO_ROOT/scripts/wait-for-rollout.sh"
PROMETHEUS_IMAGE=quay.io/prometheus/prometheus:v3.1.0

need_tools kind kubectl kustomize || exit 1
ensure_docker || exit 1
docker image inspect "$DEPLOY_IMAGE" >/dev/null 2>&1 || { log "image $DEPLOY_IMAGE missing; run the image stage first"; exit 1; }

pf_pid=""
teardown() {
  [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null
  if [ "$STEP_FAILURES" -gt 0 ]; then
    dump_cluster_state "$NS"
    kubectl -n "$NS" get analysisruns -o wide >&2 2>/dev/null
    kubectl -n "$NS" logs -l app=my-app --all-containers --tail=30 --prefix >&2 2>/dev/null
  fi
  [ "${KEEP:-0}" = 1 ] && { log "KEEP=1: kind cluster $CLUSTER left running (KUBECONFIG=$KUBECONFIG)"; return; }
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
}
trap teardown EXIT

rollout_image() { kubectl -n "$NS" get rollout/my-app -o jsonpath='{.spec.template.spec.containers[0].image}'; }

kind_cluster_up "$CLUSTER" || finish_stage

step "install Argo Rollouts controller v$ARGO_ROLLOUTS_VERSION" install_argo_rollouts || finish_stage

rendered=$(render_overlay "$NS") || exit 1
namespace_up "$rendered" || finish_stage
deps_up "$NS" "$rendered" || finish_stage

# 1. What production looks like before this fix: the base Deployment, which
#    the overlay failed to delete, running next to the Rollout.
stray_deployment() {
  local staging
  staging=$(render_overlay staging staging-for-stray-deployment) || return 1
  python3 - "$staging" <<'PY' | kubectl apply -f -
import sys, yaml
d = next(d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Deployment")
d["metadata"]["namespace"] = "production"
d["spec"]["replicas"] = 1
print(yaml.safe_dump(d))
PY
}
# Its ServiceAccount comes from the overlay, which a pre-fix cluster already has.
apply_kinds "$rendered" ServiceAccount >/dev/null
step "pre-fix state: stray Deployment running" stray_deployment

# 2. deployToKubernetes('production', image).
apply_kinds "$rendered" ConfigMap NetworkPolicy >/dev/null
step "migrations (runMigrations() from the Jenkinsfile)" jenkins_run_migrations "$NS"
step "apply production overlay" kubectl apply -f "$rendered" || finish_stage
step "wait-for-rollout.sh: first release healthy" "$WAIT_FOR_ROLLOUT" "$NS" my-app 600 || finish_stage
step "stray Deployment removed" kubectl delete deployment/my-app --namespace="$NS" --ignore-not-found
no_deployment_left() { [ -z "$(kubectl -n "$NS" get deploy -l app=my-app -o name)" ]; }
step "only the Rollout serves my-app" no_deployment_left
kubectl -n "$NS" get rollout,pods -o wide >&2
smoke_through_service "$NS" 13001 "first release"

# 3. What the canary analysis needs: Prometheus at the address the
#    AnalysisTemplate queries, scraping with the job kube-prometheus-stack gets
#    (taken from argocd/bootstrap/apps/kube-prometheus-stack.yaml, so this is
#    the real scrape config), and traffic through the Service from a stand-in
#    for the ingress controller (the app's NetworkPolicy admits the
#    ingress-nginx namespace).
prometheus_up() {
  local config
  config=$(python3 - "$REPO_ROOT/argocd/bootstrap/apps/kube-prometheus-stack.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
jobs = d["spec"]["source"]["helm"]["valuesObject"]["prometheus"]["prometheusSpec"]["additionalScrapeConfigs"]
job = next(j for j in jobs if j["job_name"] == "my-app")
print(yaml.safe_dump({"global": {"scrape_interval": "10s"}, "scrape_configs": [job]}, sort_keys=False))
PY
  ) || return 1
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null &&
    kubectl -n monitoring create configmap prometheus-config --from-literal=prometheus.yml="$config" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null &&
    kubectl apply -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: ServiceAccount
metadata: {name: prometheus, namespace: monitoring}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: harness-prometheus}
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: harness-prometheus}
subjects: [{kind: ServiceAccount, name: prometheus, namespace: monitoring}]
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: harness-prometheus}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: prometheus, namespace: monitoring}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: prometheus}}
  template:
    metadata: {labels: {app.kubernetes.io/name: prometheus}}
    spec:
      serviceAccountName: prometheus
      containers:
        - name: prometheus
          image: $PROMETHEUS_IMAGE
          args: [--config.file=/etc/prometheus/prometheus.yml, --storage.tsdb.path=/prometheus]
          ports: [{containerPort: 9090}]
          readinessProbe: {httpGet: {path: /-/ready, port: 9090}}
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus}
            - {name: data, mountPath: /prometheus}
      volumes:
        - {name: config, configMap: {name: prometheus-config}}
        - {name: data, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata: {name: prometheus-operated, namespace: monitoring}
spec:
  selector: {app.kubernetes.io/name: prometheus}
  ports: [{port: 9090, targetPort: 9090}]
EOF
  kubectl -n monitoring rollout status deploy/prometheus --timeout=180s
}
step "Prometheus with the my-app scrape job from kube-prometheus-stack" prometheus_up || finish_stage

# promql QUERY — the first result's value, from inside the Prometheus pod.
promql() {
  kubectl -n monitoring exec deploy/prometheus -- wget -qO- \
    "http://127.0.0.1:9090/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" |
    jq -r '.data.result[0].value[1] // empty'
}

# About 4 requests a second to GET /api/items, spread by the Service over the
# stable and canary pods (well under the per-client rate limit on each pod).
# A new connection per request (agent: false): the Service balances
# connections, not requests, so a kept-alive connection would send every
# request to one pod and the canary would see only its probes.
traffic_up() {
  kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f - >/dev/null &&
    kubectl -n ingress-nginx run traffic --image="$DEPLOY_IMAGE" --restart=Never --command -- \
      node -e 'const http = require("http");
        setInterval(() => http.get({host: "my-app.production.svc.cluster.local", path: "/api/items", agent: false},
          (res) => res.resume()).on("error", () => {}), 250)' >/dev/null &&
    kubectl -n ingress-nginx wait --for=condition=Ready pod/traffic --timeout=120s
}
step "traffic to the app from a stand-in for the ingress controller" traffic_up || finish_stage

# release IMAGE NAME — the overlay rendered for IMAGE with the canary's pauses
# cut to CANARY_PAUSE, then applied, as deployToKubernetes() applies it.
release() {
  local rendered
  rendered=$(DEPLOY_IMAGE=$1 render_overlay "$NS" "$2") || return 1
  python3 - "$rendered" "${CANARY_PAUSE:-30s}" <<'PY' || return 1
import sys, yaml
path, pause = sys.argv[1:]
docs = list(yaml.safe_load_all(open(path)))
for d in docs:
    if d and d.get("kind") == "Rollout":
        for s in d["spec"]["strategy"].get("canary", {}).get("steps", []):
            if isinstance(s.get("pause"), dict) and "duration" in s["pause"]:
                s["pause"]["duration"] = pause
yaml.safe_dump_all(docs, open(path, "w"), sort_keys=False)
PY
  kubectl apply -f "$rendered"
}

# analysis_runs HASH — "phase value value…" for each AnalysisRun of the pods
# with that template hash: the run's phase and every measured value.
analysis_runs() {
  kubectl -n "$NS" get analysisruns -l "rollouts-pod-template-hash=$1" -o json |
    jq -r '.items | sort_by(.metadata.creationTimestamp)[] |
      "\(.status.phase) \([.status.metricResults[]?.measurements[]?.value // "-"] | join(" "))"'
}

# 4. A release whose canary stays healthy: the analysis must measure it and
#    promote it.
good_image="${DEPLOY_IMAGE}-good"
docker tag "$DEPLOY_IMAGE" "$good_image"
step "load the healthy release's image" kind load docker-image "$good_image" --name "$CLUSTER" || finish_stage
step "apply a healthy release" release "$good_image" production-good || finish_stage
step "wait-for-rollout.sh: the healthy canary is promoted" "$WAIT_FOR_ROLLOUT" "$NS" my-app 900
good_hash=$(kubectl -n "$NS" get rollout/my-app -o jsonpath='{.status.stableRS}')
canary_measured() {
  local runs
  runs=$(analysis_runs "$good_hash"); echo "$runs"
  # One run per analysis step, all Successful, with measured values (not just
  # errors that happened to stay under the limit).
  [ "$(grep -c . <<<"$runs")" -ge 2 ] && ! grep -qv '^Successful ' <<<"$runs" &&
    grep -qE ' (\[)?[01](\.[0-9]+)?(\])?( |$)' <<<"$runs"
}
step "the analysis measured the canary and passed it" canary_measured
canary_scraped() {
  local n
  n=$(promql "count(http_request_duration_ms_count{namespace=\"production\",rollouts_pod_template_hash=\"$good_hash\"})")
  echo "series for template hash $good_hash: ${n:-none}"
  [ "${n:-0}" -gt 0 ]
}
step "Prometheus scraped the new pods with their template hash" canary_scraped
# The canary served the generated traffic, not only its probes: otherwise a
# passing analysis proves nothing.
canary_served() {
  local n
  n=$(promql "sum(http_request_duration_ms_count{namespace=\"production\",rollouts_pod_template_hash=\"$good_hash\",route=\"/api/items\"})")
  echo "GET /api/items requests on the new pods: ${n:-none}"
  [ -n "$n" ] && awk -v n="$n" 'BEGIN { exit !(n > 0) }'
}
step "the new pods served real traffic during the canary" canary_served
on_image() { local got; got=$(rollout_image); log "rollout image: $got"; [ "$got" = "$1" ]; }
step "running the healthy release" on_image "$good_image"
smoke_through_service "$NS" 13002 "healthy release"

# 5. A release whose code is broken: the app starts and passes its probes, but
#    GET /api/items fails (its query names a table that does not exist). The
#    analysis must fail it on the measured 5xx rate, wait-for-rollout.sh must
#    report it, and rollback() must put the healthy release back.
previous_image=$(rollout_image)   # what the pipeline saves as PREVIOUS_IMAGE
bad_image="${DEPLOY_IMAGE}-broken"
# Made by editing one file in a container and committing it: no builder
# involved (CI's default buildx builder cannot see local images).
broken_image() {
  local cid tmp rc=0
  tmp=$(mktemp -d)
  cid=$(docker create "$DEPLOY_IMAGE") || return 1
  docker cp "$cid:/app/dist/server.js" "$tmp/server.js" &&
    sed -i 's/FROM items ORDER BY/FROM items_missing ORDER BY/' "$tmp/server.js" &&
    grep -q items_missing "$tmp/server.js" &&
    docker cp "$tmp/server.js" "$cid:/app/dist/server.js" &&
    docker commit "$cid" "$bad_image" >/dev/null || rc=1
  docker rm "$cid" >/dev/null; rm -rf "$tmp"
  return $rc
}
step "build a release whose GET /api/items fails" broken_image || finish_stage
step "load the broken release's image" kind load docker-image "$bad_image" --name "$CLUSTER" || finish_stage
step "apply the broken release" release "$bad_image" production-broken || finish_stage
# The pipeline must see this as a failure (so post { failure } rolls back).
failed_canary_detected() {
  local phase
  if "$WAIT_FOR_ROLLOUT" "$NS" my-app 900; then log "wait-for-rollout.sh passed a failing canary"; return 1; fi
  phase=$(kubectl -n "$NS" get rollout/my-app -o jsonpath='{.status.phase}')
  log "rollout phase: $phase"
  [ "$phase" = Degraded ]
}
step "wait-for-rollout.sh reports the failed canary" failed_canary_detected
bad_hash=$(kubectl -n "$NS" get rs -l app=my-app -o json |
  jq -r --arg img "$bad_image" '.items[] | select(.spec.template.spec.containers[0].image == $img) |
    .metadata.labels["rollouts-pod-template-hash"]' | head -n1)
canary_failed_on_errors() {
  local runs
  runs=$(analysis_runs "$bad_hash"); echo "$runs"
  echo "requests on the broken pods by route and status:"
  kubectl -n monitoring exec deploy/prometheus -- wget -qO- \
    "http://127.0.0.1:9090/api/v1/query?query=$(jq -rn --arg q "sum by (route, status_code) (http_request_duration_ms_count{rollouts_pod_template_hash=\"$bad_hash\"})" '$q|@uri')" |
    jq -r '.data.result[] | "  \(.metric.route) \(.metric.status_code): \(.value[1])"' 2>/dev/null
  # Failed (not Error): a measured success rate below the 0.99 threshold.
  grep -q '^Failed ' <<<"$runs"
}
step "the analysis failed the canary on its measured error rate" canary_failed_on_errors

rollback() {
  kubectl patch rollout/my-app --namespace="$NS" --type=json -p "[
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"$previous_image\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/metadata/labels/version\", \"value\": \"${previous_image##*:}\"}
  ]"
}
step "rollback() from the Jenkinsfile" rollback
step "wait-for-rollout.sh: healthy after rollback" "$WAIT_FOR_ROLLOUT" "$NS" my-app 300
step "running the previous release again" on_image "$previous_image"
smoke_through_service "$NS" 13003 "after rollback"

finish_stage
