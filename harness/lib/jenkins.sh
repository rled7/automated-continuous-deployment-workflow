# shellcheck shell=bash
# Talking to a running Jenkins as admin. Set JENKINS_URL and JENKINS_AUTH
# (user:password) before calling; source after common.sh.

JENKINS_COOKIES=$(mktemp)

jenkins_get() { local path=$1; shift; curl -sf --max-time 60 -u "$JENKINS_AUTH" "$@" "$JENKINS_URL$path"; }

# POSTs need a CSRF crumb, tied to the session cookie it came with. A failed
# request prints its HTTP status and body.
jenkins_post() {
  local path=$1 crumb out code; shift
  crumb=$(curl -sf --max-time 60 -u "$JENKINS_AUTH" -c "$JENKINS_COOKIES" "$JENKINS_URL/crumbIssuer/api/json" |
    jq -r '.crumbRequestField + ":" + .crumb') || { echo "no CSRF crumb from $JENKINS_URL" >&2; return 1; }
  out=$(mktemp)
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time 300 -u "$JENKINS_AUTH" -b "$JENKINS_COOKIES" \
    -H "$crumb" -X POST "$@" "$JENKINS_URL$path")
  case $code in
    2??|3??) cat "$out"; rm -f "$out" ;;
    *) echo "POST $path: HTTP $code" >&2; sed 's/<[^>]*>//g' "$out" | grep -v '^\s*$' | head -20 >&2; rm -f "$out"; return 1 ;;
  esac
}

# Groovy run by Jenkins' script console, as admin.
groovy() { jenkins_post /scriptText --data-urlencode "script=$1"; }
