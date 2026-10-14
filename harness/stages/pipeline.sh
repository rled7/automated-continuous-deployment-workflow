#!/usr/bin/env bash
# Runs the Jenkinsfile for real: Jenkins (docker/jenkins/Dockerfile +
# jenkins.yaml) inside a kind cluster, where its Kubernetes cloud launches
# cicd-agent pods from docker/jenkins-agent/Dockerfile, building this working
# tree as a branch (PIPELINE_BRANCH, default develop) of a multibranch job.
# Each Jenkins stage becomes a step here, with the console log in
# logs/pipeline-console.log.
#
# Stand-ins, the only changes to jenkins.yaml:
#   - registry: a local registry (kind-registry:5000), for DOCKER_REGISTRY and
#     the agent image the pod template names (ghcr.io/YOUR_ORG/...);
#   - source: a git server in the cluster, instead of GitHub;
#   - SonarQube: a fresh server in the cluster, with a token and the quality
#     gate webhook;
#   - secrets: placeholder values, plus a kubeconfig for an in-cluster
#     service account. NVD_API_KEY comes from the environment: the
#     vulnerability database needs a real one;
#   - staging: the namespace already set up the way a long-lived one is
#     (Pod Security labels, throwaway Postgres and Redis, the app's Secret,
#     ConfigMap and NetworkPolicies), with STAGING_URL the in-cluster Service
#     and a NetworkPolicy letting the jenkins namespace in, in place of the
#     ingress path.
#
# Needs a host where kind works (your machine, GitHub Actions). KEEP=1 leaves
# the cluster up, with Jenkins on localhost:18081 (admin / verify).
source "$(dirname "$0")/../lib/common.sh"
source "$HARNESS_DIR/lib/tools.sh"
source "$HARNESS_DIR/lib/kind.sh"

CLUSTER=harness-pipeline
BRANCH="${PIPELINE_BRANCH:-develop}"
REGISTRY=kind-registry:5000        # how the cluster and the pipeline address it
HOST_REGISTRY=localhost:5001       # how this host pushes to it
JENKINS_IMAGE="$REGISTRY/jenkins-cicd:verify"
AGENT_IMAGE="$REGISTRY/jenkins-cicd-agent:verify"
GIT_URL=http://git.jenkins.svc.cluster.local/my-app.git
PIPELINE_TIMEOUT="${PIPELINE_TIMEOUT:-2700}"   # seconds for the whole build
AGENT_TIMEOUT="${AGENT_TIMEOUT:-300}"          # seconds for the first agent to connect
# dependency-check's vulnerability database, kept between runs (CI caches the
# directory) and mounted into agent pods, so the scan updates it instead of
# downloading all of NVD every time.
DC_DATA="${DEPENDENCY_CHECK_DATA_DIR:-$HARNESS_DIR/.cache/dependency-check}"
DC_NODE_PATH=/var/lib/dependency-check

JENKINS_URL="http://127.0.0.1:18081"
SONAR_URL="http://127.0.0.1:19001"
SONAR_PASSWORD="Harness-verify-1"   # SonarQube requires a complex one
SONAR_TOKEN=""
JENKINS_AUTH="admin:verify"
source "$HARNESS_DIR/lib/jenkins.sh"

need_tools kind kubectl kustomize || exit 1
[ -n "${NVD_API_KEY:-}" ] || log "NVD_API_KEY is not set: the Dependency Vulnerability Scan will fail"
ensure_docker || exit 1

work=$(mktemp -d)
teardown() {
  if [ "$STEP_FAILURES" -gt 0 ]; then
    log "agent pods and events in namespace jenkins:"
    kubectl -n jenkins get pods -o wide >&2 2>/dev/null
    kubectl -n jenkins get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 40 >&2
    kubectl -n jenkins logs deploy/jenkins --tail=60 >&2 2>/dev/null
  fi
  kubectl -n jenkins logs deploy/jenkins > "$RESULTS_DIR/logs/pipeline-jenkins.log" 2>&1
  rm -rf "$work" "$JENKINS_COOKIES"
  [ "${KEEP:-0}" = 1 ] && { log "KEEP=1: kind cluster $CLUSTER left running (KUBECONFIG=$KUBECONFIG)"; return; }
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  docker rm -f kind-registry harness-git >/dev/null 2>&1
}
trap teardown EXIT

# ── Cluster with a local registry (kind's documented setup) ─────────────────
# It needs nothing the image builds produce, so it is created in the
# background while they run.
step "pull registry:2" pull_official registry:2
step "pull busybox" pull_official busybox:1.37
cluster_up() {
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  docker rm -f kind-registry harness-git >/dev/null 2>&1
  # Jenkins is reached through a NodePort mapped to this host (a
  # port-forward stalls under load).
  cat > "$work/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - {containerPort: 30080, hostPort: ${JENKINS_URL##*:}, listenAddress: 127.0.0.1}
      - {containerPort: 30090, hostPort: ${SONAR_URL##*:}, listenAddress: 127.0.0.1}
    extraMounts:
      - {hostPath: "$DC_DATA", containerPath: $DC_NODE_PATH}
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
  kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config "$work/kind.yaml" --wait 180s || return 1
  docker run -d --name kind-registry -p "127.0.0.1:${HOST_REGISTRY#*:}:5000" registry:2 >/dev/null &&
    docker network connect kind kind-registry || return 1
  local node
  for node in $(kind get nodes --name "$CLUSTER"); do
    # Nodes pull kind-registry:5000/... over plain HTTP, and Docker Hub
    # images (SonarQube, the dind sidecar) through Google's mirror: Docker
    # Hub rate-limits CI runners.
    docker exec "$node" mkdir -p "/etc/containerd/certs.d/$REGISTRY" /etc/containerd/certs.d/docker.io || return 1
    printf '[host."http://%s"]\n' "$REGISTRY" |
      docker exec -i "$node" sh -c "cat > /etc/containerd/certs.d/$REGISTRY/hosts.toml" || return 1
    printf '%s\n' 'server = "https://registry-1.docker.io"' '[host."https://mirror.gcr.io"]' \
      '  capabilities = ["pull", "resolve"]' |
      docker exec -i "$node" sh -c "cat > /etc/containerd/certs.d/docker.io/hosts.toml" || return 1
  done
}
export KUBECONFIG="${KIND_KUBECONFIG:-$work/kubeconfig}"
# The agent image runs as uid 1000 and must be able to write the database.
mkdir -p "$DC_DATA" && chmod -R a+rwX "$DC_DATA" || exit 1
( cluster_up > "$work/cluster.log" 2>&1; echo $? > "$work/cluster.rc" ) &
cluster_pid=$!
# The Docker Build & Push stage builds linux/arm64 too, through QEMU, which
# the Jenkinsfile expects each node to have registered (binfmt_misc is the
# kernel's, so the kind node and every dind in it share the host's).
( pull_official tonistiigi/binfmt:latest && docker run --privileged --rm tonistiigi/binfmt:latest --install arm64 ) \
  > "$work/binfmt.log" 2>&1 &

# ── Images: the controller and the agent, as the jenkins stage builds them ──
for df in docker/jenkins/Dockerfile docker/jenkins-agent/Dockerfile; do
  for img in $(awk '/^FROM/{print $2}' "$REPO_ROOT/$df"); do step "pull $img" pull_base "$img"; done
done
step "build docker/jenkins/Dockerfile" \
  docker_build "$REPO_ROOT/docker/jenkins/Dockerfile" "$REPO_ROOT/docker/jenkins" -t harness-jenkins:local || finish_stage
step "build docker/jenkins-agent/Dockerfile" \
  docker_build "$REPO_ROOT/docker/jenkins-agent/Dockerfile" "$REPO_ROOT/docker/jenkins-agent" -t harness-agent:local || finish_stage

# dependency-check's database, brought up to date before the build by
# scripts/dependency-check-db-update.sh, as the nightly
# dependency-check-db-update job does in production; the scan in the build
# then reads it without downloading anything (--noupdate, since the pod
# template sets DEPENDENCY_CHECK_DATA). Needs an NVD_API_KEY NVD accepts.
# Runs while the cluster and Jenkins come up.
( timeout 2400 docker run --rm -e NVD_API_KEY -v "$DC_DATA:/data" -v "$REPO_ROOT/scripts:/scripts:ro" \
    --entrypoint bash harness-agent:local /scripts/dependency-check-db-update.sh /data > "$work/dc-update.log" 2>&1
  echo $? > "$work/dc-update.rc" ) &
dc_pid=$!

cluster_ready() { wait "$cluster_pid"; cat "$work/cluster.log"; return "$(cat "$work/cluster.rc" 2>/dev/null || echo 1)"; }
step "create kind cluster with a local registry (started before the builds)" cluster_ready || finish_stage

# SonarQube takes the better part of a minute to start: start it now and set
# it up after the next steps.
sonar_start() {
  kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f - >/dev/null &&
    kubectl apply -f "$HARNESS_DIR/fixtures/sonarqube.yaml"
}
step "start SonarQube" sonar_start || finish_stage

# ── Staging as a long-lived environment has it, for Deploy → Staging ──────
# (as cluster-real sets it up). Postgres and Redis start while SonarQube does.
staging_rendered=$(DEPLOY_IMAGE="$REGISTRY/my-app:staging-setup" render_overlay staging pipeline-staging) || finish_stage
namespace_up "$staging_rendered" || finish_stage
deps_up staging "$staging_rendered" || finish_stage
staging_state() {
  apply_kinds "$staging_rendered" ConfigMap NetworkPolicy &&
    kubectl apply -f - <<EOF
# Stand-in for the ingress path: the tests reach the app's Service directly.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: harness-allow-jenkins, namespace: staging}
spec:
  podSelector: {matchLabels: {app: my-app}}
  policyTypes: [Ingress]
  ingress:
    - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: jenkins}}}]
      ports: [{protocol: TCP, port: 3000}]
EOF
}
step "staging ConfigMap and NetworkPolicies in place" staging_state

push_images() {
  local src dst
  for pair in "harness-jenkins:local=$JENKINS_IMAGE" "harness-agent:local=$AGENT_IMAGE"; do
    src=${pair%%=*}; dst="$HOST_REGISTRY/${pair#*=$REGISTRY/}"
    docker tag "$src" "$dst" && docker push -q "$dst" || return 1
  done
}
step "push the Jenkins and agent images to the registry" push_images || finish_stage

# The pod template's other images (the dind sidecar), pulled onto the node in
# the background now, so the first agent pod does not wait for them.
template_images() {
  python3 - "$REPO_ROOT/docker/jenkins/jenkins.yaml" <<'PY'
import sys, yaml
casc = yaml.safe_load(open(sys.argv[1]))
for cloud in casc["jenkins"]["clouds"]:
    for t in cloud.get("kubernetes", {}).get("templates", []):
        containers = t.get("containers", [])
        if t.get("yaml"):
            containers += yaml.safe_load(t["yaml"]).get("spec", {}).get("containers", [])
        for c in containers:
            if "YOUR_ORG" not in c["image"]:
                print(c["image"])
PY
}
for img in $(template_images); do
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" crictl pull "$img" >/dev/null 2>&1 &
  done
done

# ── Source: this working tree (committed or not) as $BRANCH and main ────────
git_up() {
  local tree="$work/tree" bare="$work/srv/my-app.git"
  mkdir -p "$tree" "$work/srv"
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done |
    tar --null -T - -cf -) | tar -xf - -C "$tree" || return 1
  git -C "$tree" init -q -b "$BRANCH" &&
    git -C "$tree" add -A &&
    git -C "$tree" -c user.name=harness -c user.email=harness@verify.local \
      commit -q -m "$(git -C "$REPO_ROOT" log -1 --format=%s 2>/dev/null || echo 'working tree')" &&
    git -C "$tree" branch -f main &&
    git clone -q --bare "$tree" "$bare" &&
    git -C "$bare" update-server-info || return 1
  chmod -R a+rX "$work/srv"
  # Git's "dumb" HTTP protocol: static files are enough.
  docker run -d --name harness-git --network kind -v "$work/srv:/srv/git:ro" busybox:1.37 \
    httpd -f -p 80 -h /srv/git >/dev/null
}
step "serve the working tree over git" git_up || finish_stage

# Services in namespace jenkins for the two containers on the kind network,
# so agent pods (and the Docker daemons and builders they start) resolve them.
ip_on_kind() { docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$1"; }
external_service() {
  local name=$1 ip=$2 port=$3
  cat <<EOF
apiVersion: v1
kind: Service
metadata: {name: $name, namespace: jenkins}
spec:
  ports: [{port: $port, targetPort: $port}]
---
apiVersion: v1
kind: Endpoints
metadata: {name: $name, namespace: jenkins}
subsets:
  - addresses: [{ip: $ip}]
    ports: [{port: $port}]
---
EOF
}

# ── SonarQube, the server jenkins.yaml names ────────────────────────────────
# A token for the sonarqube-token credential, and the webhook through which
# SonarQube reports the quality gate to Jenkins (waitForQualityGate).
sonar_up() {
  kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f - >/dev/null &&
    kubectl apply -f "$HARNESS_DIR/fixtures/sonarqube.yaml" >/dev/null || return 1
  local deadline=$(( $(date +%s) + 600 )) status=""
  until [ "$status" = UP ]; do
    [ "$(date +%s)" -gt "$deadline" ] && { echo "SonarQube not UP after 10 minutes (last: ${status:-no answer})";
      kubectl -n jenkins logs deploy/sonarqube --tail=30; return 1; }
    sleep 5
    status=$(curl -s --max-time 10 "$SONAR_URL/api/system/status" | jq -r '.status // empty' 2>/dev/null)
    # The embedded Elasticsearch makes its indices read-only when the host
    # disk is over 95% used (common on CI runners and sandboxes), and
    # SonarQube then never leaves STARTING. Turn the disk thresholds off.
    [ "$status" = STARTING ] && kubectl -n jenkins exec deploy/sonarqube -- sh -c '
      curl -s -X PUT localhost:9001/_cluster/settings -H "Content-Type: application/json" \
        -d "{\"persistent\":{\"cluster.routing.allocation.disk.threshold_enabled\":false}}" &&
      curl -s -X PUT localhost:9001/_all/_settings -H "Content-Type: application/json" \
        -d "{\"index.blocks.read_only_allow_delete\":null}"' >/dev/null 2>&1
  done
  curl -sf --max-time 60 -u admin:admin -X POST "$SONAR_URL/api/users/change_password" \
    -d login=admin -d previousPassword=admin -d password="$SONAR_PASSWORD" || { echo "could not set the admin password"; return 1; }
  # The webhook and token, the way a real setup creates them.
  local out
  out=$(SONAR_URL="$SONAR_URL" SONAR_ADMIN_PASSWORD="$SONAR_PASSWORD" \
    JENKINS_WEBHOOK_URL=http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/ \
    "$REPO_ROOT/scripts/sonarqube-setup.sh") || { echo "$out"; return 1; }
  grep -v '^SONAR_TOKEN=' <<<"$out"
  SONAR_TOKEN=$(sed -n 's/^SONAR_TOKEN=//p' <<<"$out")
  [ -n "$SONAR_TOKEN" ] || { echo "scripts/sonarqube-setup.sh printed no token"; return 1; }
}
step "SonarQube up (token, quality gate webhook)" sonar_up || finish_stage

# ── Jenkins in the cluster ──────────────────────────────────────────────────
jenkins_up() {
  sed "s|__JENKINS_IMAGE__|$JENKINS_IMAGE|" "$HARNESS_DIR/fixtures/jenkins-in-cluster.yaml" | kubectl apply -f - >/dev/null || return 1
  { external_service kind-registry "$(ip_on_kind kind-registry)" 5000
    external_service git "$(ip_on_kind harness-git)" 80; } | kubectl apply -f - >/dev/null || return 1

  # jenkins.yaml with the stand-in agent image; the dependency-check
  # database mounted from the node where production would mount a volume;
  # and the stand-in registry, which speaks plain HTTP, allowed for the Docker
  # daemon (dind), the buildx builder (BUILDKITD_CONFIG), Trivy, Syft and cosign.
  sed "s|ghcr.io/YOUR_ORG/jenkins-cicd-agent:latest|$AGENT_IMAGE|" "$REPO_ROOT/docker/jenkins/jenkins.yaml" > "$work/jenkins.yaml"
  grep -q "$AGENT_IMAGE" "$work/jenkins.yaml" || { echo "agent image not found in jenkins.yaml"; return 1; }
  printf '[registry."%s"]\n  http = true\n  insecure = true\n' "$REGISTRY" > "$work/buildkitd.toml"
  kubectl -n jenkins create configmap harness-buildkitd --from-file=buildkitd.toml="$work/buildkitd.toml" >/dev/null || return 1
  # A throwaway signing key for cosign (COSIGN_KEY, set in jenkins-env below),
  # where production names a KMS key or a key secret.
  mkdir -p "$work/cosign"
  docker run --rm --user "$(id -u)" -v "$work/cosign:/k" -w /k -e COSIGN_PASSWORD=verify \
    --entrypoint cosign harness-agent:local generate-key-pair >/dev/null 2>&1 || return 1
  kubectl -n jenkins create secret generic harness-cosign --from-file=cosign.key="$work/cosign/cosign.key" >/dev/null || return 1
  python3 - "$work/jenkins.yaml" "$DC_NODE_PATH" "$REGISTRY" <<'PY2' || return 1
import sys, yaml
path, data, registry = sys.argv[1:]
casc = yaml.safe_load(open(path))
env = {
    "DEPENDENCY_CHECK_DATA": data,
    "BUILDKITD_CONFIG": "/etc/harness-buildkitd/buildkitd.toml",
    "TRIVY_INSECURE": "true",
    "SYFT_REGISTRY_INSECURE_USE_HTTP": "true",
    "COSIGN_PASSWORD": "verify",
    # Plain HTTP, and no entries in the public Rekor log for a test registry.
    "COSIGN_EXTRA_ARGS": "--allow-http-registry --tlog-upload=false",
}
for cloud in casc["jenkins"]["clouds"]:
    for t in cloud.get("kubernetes", {}).get("templates", []):
        if t["name"] != "cicd-agent":
            continue
        t.setdefault("volumes", []).extend([
            {"hostPathVolume": {"hostPath": data, "mountPath": data}},
            {"configMapVolume": {"configMapName": "harness-buildkitd", "mountPath": "/etc/harness-buildkitd"}},
            {"secretVolume": {"secretName": "harness-cosign", "mountPath": "/etc/harness-cosign"}},
        ])
        t.setdefault("envVars", []).extend({"envVar": {"key": k, "value": v}} for k, v in env.items())
        for c in t["containers"]:
            if c["name"] == "dind":
                c["args"] += f" --insecure-registry={registry}"
yaml.safe_dump(casc, open(path, "w"), sort_keys=False, width=10**6)
PY2
  kubectl -n jenkins create configmap jenkins-casc --from-file=jenkins.yaml="$work/jenkins.yaml" >/dev/null || return 1

  kubectl -n jenkins create secret generic jenkins-env \
    --from-literal=JENKINS_ADMIN_PASSWORD=verify \
    --from-literal=DOCKER_REGISTRY="$REGISTRY" --from-literal=DOCKER_USER=verify --from-literal=DOCKER_PASSWORD=verify \
    --from-literal=SONAR_TOKEN="$SONAR_TOKEN" --from-literal=NVD_API_KEY="${NVD_API_KEY:-}" \
    --from-literal=STAGING_URL=http://my-app.staging.svc.cluster.local \
    --from-literal=PRODUCTION_URL=http://my-app.production.svc.cluster.local \
    --from-literal=COSIGN_KEY=/etc/harness-cosign/cosign.key \
    --from-literal=SLACK_TOKEN=verify --from-literal=SLACK_WORKSPACE=verify \
    --from-literal=GITHUB_USER=verify --from-literal=GITHUB_TOKEN=verify >/dev/null || return 1

  # The kubeconfig credential: the in-cluster API server, as jenkins-deployer.
  local ca token
  ca=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  token=$(kubectl -n jenkins create token jenkins-deployer --duration=4h) || return 1
  cat > "$work/deployer-kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: in-cluster, cluster: {server: "https://kubernetes.default.svc", certificate-authority-data: "$ca"}}]
users: [{name: jenkins-deployer, user: {token: "$token"}}]
contexts: [{name: in-cluster, context: {cluster: in-cluster, user: jenkins-deployer}}]
current-context: in-cluster
EOF
  kubectl -n jenkins create secret generic jenkins-kubeconfig --from-file=kubeconfig="$work/deployer-kubeconfig" >/dev/null || return 1

  kubectl -n jenkins rollout status deploy/jenkins --timeout=600s
}
step "Jenkins starts in the cluster with jenkins.yaml" jenkins_up || finish_stage

jenkins_reachable() {
  kubectl apply -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: Service
metadata: {name: jenkins-harness, namespace: jenkins}
spec:
  type: NodePort
  selector: {app: jenkins}
  ports: [{port: 8080, targetPort: 8080, nodePort: 30080}]
EOF
  wait_http "$JENKINS_URL/login" 60
}
step "Jenkins reachable from this host" jenkins_reachable || finish_stage

# ── The job: multibranch over the git server; builds only when asked ────────
create_job() {
  groovy "
import jenkins.branch.*
import jenkins.plugins.git.GitSCMSource
import jenkins.plugins.git.traits.BranchDiscoveryTrait
import org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject
def j = jenkins.model.Jenkins.get()
def mb = j.createProject(WorkflowMultiBranchProject, 'verify')
def src = new GitSCMSource('$GIT_URL')
src.id = 'verify'
src.traits = [new BranchDiscoveryTrait()]
def bs = new BranchSource(src)
bs.strategy = new DefaultBranchPropertyStrategy([new NoTriggerBranchProperty()] as BranchProperty[])
mb.sourcesList.add(bs)
mb.save()
mb.scheduleBuild2(0)
println('created')" | tee /dev/stderr | grep -qx created
}
step "create multibranch job over the git server" create_job || finish_stage

JOB="/job/verify/job/$BRANCH"
branch_indexed() {
  local deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    jenkins_get "$JOB/api/json" >/dev/null && return 0
    sleep 3
  done
  echo "branch $BRANCH not found by indexing; indexing log:"
  jenkins_get /job/verify/indexing/consoleText | tail -30
  return 1
}
step "branch $BRANCH discovered" branch_indexed || finish_stage

build_json() { jenkins_get "$JOB/1/api/json"; }
console() { jenkins_get "$JOB/1/consoleText"; }

# One build; first it waits for an agent pod, then for the build to finish.
run_build() {
  jenkins_post "$JOB/build" >/dev/null || { echo "could not start the build"; return 1; }
  local start; start=$(date +%s)
  until build_json >/dev/null; do
    [ $(( $(date +%s) - start )) -gt 120 ] && { echo "build never left the queue"; return 1; }
    sleep 3
  done
  echo "build started"
}
dc_updated() {
  wait "$dc_pid"; grep -vE '^\s+at ' "$work/dc-update.log" | tail -n 20
  return "$(cat "$work/dc-update.rc" 2>/dev/null || echo 1)"
}
step "dependency-check database up to date (started with the cluster)" dc_updated
step "start build of $BRANCH" run_build || finish_stage

agent_connected() {
  local deadline=$(( $(date +%s) + AGENT_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    console | grep -q "^Running on " && { console | grep -m1 "^Running on "; return 0; }
    [ "$(build_json | jq -r .building)" = false ] && break
    sleep 5
  done
  echo "no agent connected within ${AGENT_TIMEOUT}s; end of the console log:"
  console | tail -30
  echo "agent pods:"
  kubectl -n jenkins get pods -l jenkins/label -o wide 2>&1
  for p in $(kubectl -n jenkins get pods -o name 2>/dev/null | grep -v jenkins-); do
    kubectl -n jenkins describe "$p" | sed -n '/^Events:/,$p' | tail -15
  done
  return 1
}
if ! step "an agent pod starts and connects" agent_connected; then
  jenkins_post "$JOB/1/stop" >/dev/null
  console > "$RESULTS_DIR/logs/pipeline-console.log" 2>/dev/null
  finish_stage
fi

build_done() {
  local deadline=$(( $(date +%s) + PIPELINE_TIMEOUT )) last="" now
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(build_json | jq -r .building)" = false ] && { build_json | jq -r '"result: \(.result)"'; return 0; }
    now=$(jenkins_get "$JOB/1/wfapi/describe" | jq -r '[.stages[] | select(.status=="IN_PROGRESS") | .name] | join(", ")')
    [ "$now" != "$last" ] && [ -n "$now" ] && { log "   running: $now"; last=$now; }
    sleep 10
  done
  echo "build still running after ${PIPELINE_TIMEOUT}s; stopping it"
  jenkins_post "$JOB/1/stop" >/dev/null
  return 1
}
step "build finishes" build_done
console > "$RESULTS_DIR/logs/pipeline-console.log"

# Each Jenkins stage as a step: pass, fail (with the end of its log), or skip
# (its `when` condition, or an earlier failure, kept it from running). The
# stage API reports a stage skipped after a failure as FAILED; the console
# says which ones were skipped and why.
record_stages() {
  local build=$1 prefix=$2 describe skipped
  describe=$(jenkins_get "$build/wfapi/describe") || return 1
  skipped=$(jenkins_get "$build/consoleText" | sed -n 's/^.*Stage "\(.*\)" skipped due to \(.*\)$/\1\t\2/p')
  jq -c '.stages[] | {name, status, ms: .durationMillis, id}' <<<"$describe" | while read -r s; do
    local name status id tail="" why
    name=$(jq -r .name <<<"$s"); status=$(jq -r .status <<<"$s"); id=$(jq -r .id <<<"$s")
    why=$(awk -F'\t' -v n="$name" '$1 == n {print $2; exit}' <<<"$skipped")
    [ -n "$why" ] && status="SKIPPED ($why)"
    case $status in
      SUCCESS) st=pass ;;
      NOT_EXECUTED|SKIPPED*) st=skip ;;
      # A stage's output lives on its step nodes.
      *) st=fail
         tail=$(for n in $(jenkins_get "$build/execution/node/$id/wfapi/describe" | jq -r '.stageFlowNodes[]?.id'); do
                  jenkins_get "$build/execution/node/$n/wfapi/log" | jq -r '.text // ""'
                done | sed 's/<[^>]*>//g' | tail -n "$STEP_TAIL_LINES") ;;
    esac
    log "   $st ($prefix: $name — $status)"
    jq -nc --arg name "$prefix: $name" --arg status "$st" --arg js "$status" \
      --argjson secs "$(( $(jq -r .ms <<<"$s") / 1000 ))" --arg tail "$tail" \
      '{name:$name,status:$status,jenkins_status:$js,seconds:$secs}
       + (if $tail != "" then {output_tail:$tail} else {} end)' >> "$STEPS_FILE"
    [ "$st" = fail ] && echo fail
  done
}
[ -n "$(record_stages "$JOB/1" "Jenkins stage")" ] && STEP_FAILURES=$((STEP_FAILURES + 1))

result_success() { build_json | jq -e '.result == "SUCCESS"' >/dev/null || { build_json | jq -r .result; console | tail -40; return 1; }; }
step "build result is SUCCESS" result_success

# ── Every way of asking for an agent, run for real ──────────────────────────
# fixtures/agent-forms.Jenkinsfile: one stage per syntax (inheritFrom, the
# deprecated kubernetes label, a yaml-only pod, label, any), each checking its
# steps have the tools and a Docker daemon. The jenkins stage resolves the
# same file offline. See docs/agent-resolution.md.
FORMS=/job/agent-forms
run_agent_forms() {
  groovy "
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import org.jenkinsci.plugins.workflow.job.WorkflowJob
def job = jenkins.model.Jenkins.get().createProject(WorkflowJob, 'agent-forms')
job.definition = new CpsFlowDefinition(new String(Base64.decoder.decode('$(base64 -w0 "$HARNESS_DIR/fixtures/agent-forms.Jenkinsfile")'), 'UTF-8'), true)
job.save()
println('created')" | grep -qx created || { echo "could not create the agent-forms job"; return 1; }
  jenkins_post "$FORMS/build" >/dev/null || return 1
  local deadline=$(( $(date +%s) + 1800 ))
  until [ "$(jenkins_get "$FORMS/1/api/json" | jq -r .building)" = false ]; do
    [ "$(date +%s)" -gt "$deadline" ] && { echo "agent-forms still running after 30 minutes"; jenkins_post "$FORMS/1/stop" >/dev/null; return 1; }
    sleep 10
  done
  jenkins_get "$FORMS/1/consoleText" > "$RESULTS_DIR/logs/pipeline-agent-forms.log"
  jenkins_get "$FORMS/1/api/json" | jq -r '"result: \(.result)"'
}
step "agent-forms job runs" run_agent_forms
[ -n "$(record_stages "$FORMS/1" "agent form")" ] && STEP_FAILURES=$((STEP_FAILURES + 1))

finish_stage
