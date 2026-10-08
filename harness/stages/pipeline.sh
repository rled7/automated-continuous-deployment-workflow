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
#     service account.
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

JENKINS_URL="http://127.0.0.1:18081"
SONAR_URL="http://127.0.0.1:19001"
SONAR_IMAGE=sonarqube:10.7.0-community
SONAR_PASSWORD="Harness-verify-1"   # SonarQube requires a complex one
SONAR_TOKEN=""
JENKINS_AUTH="admin:verify"
source "$HARNESS_DIR/lib/jenkins.sh"

need_tools kind kubectl || exit 1
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

# ── Images: the controller and the agent, as the jenkins stage builds them ──
for df in docker/jenkins/Dockerfile docker/jenkins-agent/Dockerfile; do
  for img in $(awk '/^FROM/{print $2}' "$REPO_ROOT/$df"); do step "pull $img" pull_official "$img"; done
done
step "build docker/jenkins/Dockerfile" \
  docker_build "$REPO_ROOT/docker/jenkins/Dockerfile" "$REPO_ROOT/docker/jenkins" -t harness-jenkins:local || finish_stage
step "build docker/jenkins-agent/Dockerfile" \
  docker_build "$REPO_ROOT/docker/jenkins-agent/Dockerfile" "$REPO_ROOT/docker/jenkins-agent" -t harness-agent:local || finish_stage
step "pull registry:2" pull_official registry:2
step "pull busybox" pull_official busybox:1.37

# ── Cluster with a local registry (kind's documented setup) ─────────────────
cluster_up() {
  export KUBECONFIG="${KIND_KUBECONFIG:-$work/kubeconfig}"
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
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
  kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --config "$work/kind.yaml" --wait 180s || return 1
  docker run -d --name kind-registry -p "127.0.0.1:${HOST_REGISTRY#*:}:5000" registry:2 >/dev/null &&
    docker network connect kind kind-registry || return 1
  # Nodes pull kind-registry:5000/... over plain HTTP.
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" sh -c "mkdir -p /etc/containerd/certs.d/$REGISTRY &&
      printf '[host.\"http://$REGISTRY\"]\n' > /etc/containerd/certs.d/$REGISTRY/hosts.toml" || return 1
  done
}
export KUBECONFIG="${KIND_KUBECONFIG:-$work/kubeconfig}"
step "create kind cluster with a local registry" cluster_up || finish_stage

push_images() {
  local src dst
  for pair in "harness-jenkins:local=$JENKINS_IMAGE" "harness-agent:local=$AGENT_IMAGE"; do
    src=${pair%%=*}; dst="$HOST_REGISTRY/${pair#*=$REGISTRY/}"
    docker tag "$src" "$dst" && docker push -q "$dst" || return 1
  done
}
step "push the Jenkins and agent images to the registry" push_images || finish_stage

# Other images the pod template runs (the dind sidecar), loaded into the
# nodes so they are not pulled from Docker Hub, which rate-limits CI runners.
template_images() {
  python3 - "$REPO_ROOT/docker/jenkins/jenkins.yaml" <<'PY'
import sys, yaml
casc = yaml.safe_load(open(sys.argv[1]))
for cloud in casc["jenkins"]["clouds"]:
    for t in cloud.get("kubernetes", {}).get("templates", []):
        for c in yaml.safe_load(t["yaml"])["spec"]["containers"]:
            if "YOUR_ORG" not in c["image"]:
                print(c["image"])
PY
}
load_template_images() {
  local img
  for img in $(template_images) "$SONAR_IMAGE"; do
    pull_official "$img" && kind load docker-image "$img" --name "$CLUSTER" >/dev/null || { echo "could not load $img"; return 1; }
    echo "loaded $img"
  done
}
step "load the pod template's other images and SonarQube into the cluster" load_template_images || finish_stage

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
sonar_api() { local path=$1; shift; curl -sf --max-time 60 -u "admin:$SONAR_PASSWORD" -X POST "$@" "$SONAR_URL$path"; }
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
  SONAR_TOKEN=$(sonar_api /api/user_tokens/generate -d name=jenkins -d type=USER_TOKEN | jq -r .token)
  [ -n "$SONAR_TOKEN" ] && [ "$SONAR_TOKEN" != null ] || { echo "could not create a token"; return 1; }
  sonar_api /api/webhooks/create -d name=jenkins \
    -d url=http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/ >/dev/null || { echo "could not create the webhook"; return 1; }
  echo "SonarQube up; token and Jenkins webhook created"
}
step "SonarQube starts (token, quality gate webhook)" sonar_up || finish_stage

# ── Jenkins in the cluster ──────────────────────────────────────────────────
jenkins_up() {
  sed "s|__JENKINS_IMAGE__|$JENKINS_IMAGE|" "$HARNESS_DIR/fixtures/jenkins-in-cluster.yaml" | kubectl apply -f - >/dev/null || return 1
  { external_service kind-registry "$(ip_on_kind kind-registry)" 5000
    external_service git "$(ip_on_kind harness-git)" 80; } | kubectl apply -f - >/dev/null || return 1

  # jenkins.yaml with the stand-in agent image.
  sed "s|ghcr.io/YOUR_ORG/jenkins-cicd-agent:latest|$AGENT_IMAGE|" "$REPO_ROOT/docker/jenkins/jenkins.yaml" > "$work/jenkins.yaml"
  grep -q "$AGENT_IMAGE" "$work/jenkins.yaml" || { echo "agent image not found in jenkins.yaml"; return 1; }
  kubectl -n jenkins create configmap jenkins-casc --from-file=jenkins.yaml="$work/jenkins.yaml" >/dev/null || return 1

  kubectl -n jenkins create secret generic jenkins-env \
    --from-literal=JENKINS_ADMIN_PASSWORD=verify \
    --from-literal=DOCKER_REGISTRY="$REGISTRY" --from-literal=DOCKER_USER=verify --from-literal=DOCKER_PASSWORD=verify \
    --from-literal=SONAR_TOKEN="$SONAR_TOKEN" --from-literal=SLACK_TOKEN=verify --from-literal=SLACK_WORKSPACE=verify \
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
  local describe skipped
  describe=$(jenkins_get "$JOB/1/wfapi/describe") || return 1
  skipped=$(console | sed -n 's/^.*Stage "\(.*\)" skipped due to \(.*\)$/\1\t\2/p')
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
         tail=$(for n in $(jenkins_get "$JOB/1/execution/node/$id/wfapi/describe" | jq -r '.stageFlowNodes[]?.id'); do
                  jenkins_get "$JOB/1/execution/node/$n/wfapi/log" | jq -r '.text // ""'
                done | sed 's/<[^>]*>//g' | tail -n "$STEP_TAIL_LINES") ;;
    esac
    log "   $st (Jenkins stage: $name — $status)"
    jq -nc --arg name "Jenkins stage: $name" --arg status "$st" --arg js "$status" \
      --argjson secs "$(( $(jq -r .ms <<<"$s") / 1000 ))" --arg tail "$tail" \
      '{name:$name,status:$status,jenkins_status:$js,seconds:$secs}
       + (if $tail != "" then {output_tail:$tail} else {} end)' >> "$STEPS_FILE"
    [ "$st" = fail ] && echo fail
  done
}
[ -n "$(record_stages)" ] && STEP_FAILURES=$((STEP_FAILURES + 1))

result_success() { build_json | jq -e '.result == "SUCCESS"' >/dev/null || { build_json | jq -r .result; console | tail -40; return 1; }; }
step "build result is SUCCESS" result_success

finish_stage
