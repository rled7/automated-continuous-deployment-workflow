#!/usr/bin/env bash
# Boot the Jenkins controller the way docker/docker-compose.yml does —
# docker/jenkins/Dockerfile (plugins.txt baked in) with jenkins.yaml (JCasC)
# and placeholder secrets — then check it against the Jenkinsfile from inside
# the running Jenkins: it starts, the jobs exist, every credential and agent
# label the pipeline uses is defined, and Jenkins' own declarative validator
# accepts the Jenkinsfile. KEEP=1 leaves it running on localhost:18080
# (admin / verify).
source "$(dirname "$0")/../lib/common.sh"

PORT="${JENKINS_PORT:-18080}"
URL="http://127.0.0.1:$PORT"
AUTH="admin:verify"
IMAGE="harness-jenkins:local"
CTR=harness-jenkins

ensure_docker || exit 1

teardown() {
  docker logs "$CTR" > "$RESULTS_DIR/logs/jenkins-controller.log" 2>&1
  [ "${KEEP:-0}" = 1 ] && { log "KEEP=1: Jenkins left running at $URL ($AUTH)"; return; }
  docker rm -f "$CTR" >/dev/null 2>&1
  rm -f "${COOKIES:-}"
}
trap teardown EXIT

base=$(awk '/^FROM/{print $2; exit}' "$REPO_ROOT/docker/jenkins/Dockerfile")
step "pull $base" pull_official "$base"
step "build docker/jenkins/Dockerfile (plugins.txt)" \
  docker_build "$REPO_ROOT/docker/jenkins/Dockerfile" "$REPO_ROOT/docker/jenkins" -t "$IMAGE" || finish_stage

# Placeholder values for every variable jenkins.yaml substitutes; .env.example
# is the list of what a real setup provides.
start_jenkins() {
  docker rm -f "$CTR" >/dev/null 2>&1
  docker run -d --name "$CTR" -p "127.0.0.1:$PORT:8080" \
    -e JAVA_OPTS=-Djenkins.install.runSetupWizard=false \
    -e CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs \
    -e JENKINS_ADMIN_PASSWORD=verify \
    -e DOCKER_REGISTRY=registry.verify.local:5000 -e DOCKER_USER=verify -e DOCKER_PASSWORD=verify \
    -e SONAR_TOKEN=verify -e SLACK_TOKEN=verify -e SLACK_WORKSPACE=verify \
    -e GITHUB_USER=verify -e GITHUB_TOKEN=verify \
    -v "$REPO_ROOT/docker/jenkins/jenkins.yaml:/var/jenkins_home/casc_configs/jenkins.yaml:ro" \
    -v "$REPO_ROOT/docker/jenkins/kubeconfig.placeholder:/run/secrets/kubeconfig:ro" \
    "$IMAGE" >/dev/null
}
step "start Jenkins with jenkins.yaml" start_jenkins || finish_stage

# Jenkins logs one of these within a few minutes: up, or a boot failure (an
# invalid jenkins.yaml stops it here).
booted() {
  local deadline=$(( $(date +%s) + 300 )) logs
  while [ "$(date +%s)" -lt "$deadline" ]; do
    logs=$(docker logs "$CTR" 2>&1)
    if grep -qE "BootFailure|Failed to initialize Jenkins|ConfiguratorException" <<<"$logs"; then
      # The exception messages say what in jenkins.yaml is wrong.
      grep -vE '^\s+at ' <<<"$logs" | grep -E "Exception:|SEVERE" | sort -u | head -20
      return 1
    fi
    grep -q "Jenkins is fully up and running" <<<"$logs" && return 0
    sleep 3
  done
  echo "Jenkins did not come up within 5 minutes"; return 1
}
step "Jenkins boots with jenkins.yaml applied" booted || finish_stage

# POSTs to Jenkins need a CSRF crumb, tied to the session cookie it came with.
COOKIES=$(mktemp)
jenkins_post() {
  local path=$1 crumb; shift
  crumb=$(curl -sf -u "$AUTH" -c "$COOKIES" "$URL/crumbIssuer/api/json" | jq -r '.crumbRequestField + ":" + .crumb') || return 1
  curl -sf -u "$AUTH" -b "$COOKIES" -H "$crumb" -X POST "$@" "$URL$path"
}

# Groovy run by Jenkins' script console, as admin.
groovy() { jenkins_post /scriptText --data-urlencode "script=$1"; }

jobs_exist() {
  local jobs; jobs=$(groovy 'println(jenkins.model.Jenkins.instance.allItems*.fullName.join(" "))')
  echo "jobs: $jobs"
  for j in my-app pr-preview-teardown; do grep -qw "$j" <<<"$jobs" || { echo "missing job $j"; return 1; }; done
}
step "jobs from jenkins.yaml exist" jobs_exist

# Credentials the Jenkinsfile asks for (credentials('id'), credentialsId: 'id'),
# ignoring comment lines, against the ones Jenkins actually has.
credentials_defined() {
  local wanted have missing=0
  wanted=$(grep -vE '^\s*//' "$REPO_ROOT/Jenkinsfile" |
    grep -oE "credentials\('[^']+'\)|credentialsId: *'[^']+'" | sed -E "s/.*'([^']+)'.*/\1/" | sort -u)
  have=$(groovy 'import com.cloudbees.plugins.credentials.CredentialsProvider
println(CredentialsProvider.lookupCredentials(com.cloudbees.plugins.credentials.common.StandardCredentials, jenkins.model.Jenkins.instance, null, null).collect { it.id + ":" + it.class.simpleName }.join("\n"))')
  echo "defined:"; sed 's/^/  /' <<<"$have"
  for id in $wanted; do
    if grep -q "^$id:" <<<"$have"; then echo "ok      $id"; else echo "MISSING $id"; missing=1; fi
  done
  return $missing
}
step "every credential the Jenkinsfile uses is defined" credentials_defined

agent_labels_defined() {
  local wanted have missing=0
  wanted=$(grep -vE '^\s*//' "$REPO_ROOT/Jenkinsfile" | grep -oE "label +'[^']+'" | sed -E "s/.*'([^']+)'.*/\1/" | sort -u)
  have=$(groovy 'println(jenkins.model.Jenkins.instance.clouds.collectMany { c -> c.respondsTo("getTemplates") ? c.templates*.label : [] }.join(" "))')
  echo "agent labels in clouds: $have"
  for l in $wanted; do grep -qw "$l" <<<"$have" || { echo "MISSING agent label $l"; missing=1; }; done
  return $missing
}
step "agent labels the Jenkinsfile uses are defined" agent_labels_defined

# The declarative linter Jenkins exposes (what `jenkins-cli declarative-linter`
# calls).
validate_jenkinsfile() {
  local out
  out=$(jenkins_post /pipeline-model-converter/validate -F "jenkinsfile=<$REPO_ROOT/Jenkinsfile")
  echo "$out"
  grep -q "Jenkinsfile successfully validated" <<<"$out"
}
step "Jenkinsfile passes Jenkins' declarative validation" validate_jenkinsfile

finish_stage
