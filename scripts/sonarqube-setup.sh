#!/usr/bin/env bash
# Prepare a SonarQube server for the Jenkinsfile's SonarQube Analysis stage.
#
#   - the webhook that tells Jenkins a project's quality gate result; without
#     it `waitForQualityGate` waits its full 5 minutes and fails every build;
#   - a token for Jenkins (the sonarqube-token credential, SONAR_TOKEN in
#     .env), printed once when it is created.
#
# Safe to run again: an existing webhook or token is left as it is.
#
# Usage: SONAR_ADMIN_PASSWORD=... scripts/sonarqube-setup.sh
#   SONAR_URL             SonarQube, as this machine reaches it
#                         (default http://localhost:9000)
#   SONAR_ADMIN_USER      default admin
#   SONAR_ADMIN_PASSWORD  required. A fresh server's admin password is
#                         "admin" and must be changed at first login.
#   JENKINS_WEBHOOK_URL   Jenkins' webhook endpoint, as SonarQube reaches it
#                         (default http://jenkins:8080/sonarqube-webhook/,
#                         the docker-compose service)
#   SONAR_TOKEN_NAME      default jenkins
#   SONAR_WAIT            seconds to wait for SonarQube to be UP (default 300)
set -euo pipefail

SONAR_URL="${SONAR_URL:-http://localhost:9000}"
SONAR_ADMIN_USER="${SONAR_ADMIN_USER:-admin}"
: "${SONAR_ADMIN_PASSWORD:?set SONAR_ADMIN_PASSWORD}"
JENKINS_WEBHOOK_URL="${JENKINS_WEBHOOK_URL:-http://jenkins:8080/sonarqube-webhook/}"
SONAR_TOKEN_NAME="${SONAR_TOKEN_NAME:-jenkins}"
SONAR_WAIT="${SONAR_WAIT:-300}"

api() {
  local method=$1 path=$2; shift 2
  curl -sf --max-time 60 -u "$SONAR_ADMIN_USER:$SONAR_ADMIN_PASSWORD" -X "$method" "$@" "$SONAR_URL$path"
}

deadline=$(( $(date +%s) + SONAR_WAIT ))
until [ "$(curl -s --max-time 10 "$SONAR_URL/api/system/status" | jq -r '.status // empty' 2>/dev/null)" = UP ]; do
  [ "$(date +%s)" -lt "$deadline" ] || { echo "SonarQube at $SONAR_URL is not UP after ${SONAR_WAIT}s" >&2; exit 1; }
  sleep 5
done
api GET /api/authentication/validate | jq -e '.valid' >/dev/null ||
  { echo "SonarQube rejected $SONAR_ADMIN_USER's password" >&2; exit 1; }

if api GET /api/webhooks/list | jq -e --arg url "$JENKINS_WEBHOOK_URL" '.webhooks[] | select(.url == $url)' >/dev/null; then
  echo "webhook to $JENKINS_WEBHOOK_URL: already there"
else
  api POST /api/webhooks/create -d name=jenkins --data-urlencode "url=$JENKINS_WEBHOOK_URL" >/dev/null
  echo "webhook to $JENKINS_WEBHOOK_URL: created"
fi

if api GET /api/user_tokens/search | jq -e --arg n "$SONAR_TOKEN_NAME" '.userTokens[] | select(.name == $n)' >/dev/null; then
  echo "token $SONAR_TOKEN_NAME: already there (SonarQube shows a token only once; revoke it in My Account → Security to get a new one)"
else
  token=$(api POST /api/user_tokens/generate -d "name=$SONAR_TOKEN_NAME" -d type=USER_TOKEN | jq -r .token)
  echo "token $SONAR_TOKEN_NAME: created. Put it in .env:"
  echo "SONAR_TOKEN=$token"
fi
