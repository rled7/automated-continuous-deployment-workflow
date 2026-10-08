# shellcheck shell=bash
# Talking to a running Jenkins as admin. Set JENKINS_URL and JENKINS_AUTH
# (user:password) before calling; source after common.sh.

JENKINS_COOKIES=$(mktemp)

jenkins_get() { local path=$1; shift; curl -sf -u "$JENKINS_AUTH" "$@" "$JENKINS_URL$path"; }

# POSTs need a CSRF crumb, tied to the session cookie it came with.
jenkins_post() {
  local path=$1 crumb; shift
  crumb=$(curl -sf -u "$JENKINS_AUTH" -c "$JENKINS_COOKIES" "$JENKINS_URL/crumbIssuer/api/json" |
    jq -r '.crumbRequestField + ":" + .crumb') || return 1
  curl -sf -u "$JENKINS_AUTH" -b "$JENKINS_COOKIES" -H "$crumb" -X POST "$@" "$JENKINS_URL$path"
}

# Groovy run by Jenkins' script console, as admin.
groovy() { jenkins_post /scriptText --data-urlencode "script=$1"; }
