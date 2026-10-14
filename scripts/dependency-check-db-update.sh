#!/usr/bin/env bash
# Bring dependency-check's vulnerability database up to date, for builds that
# then scan with --noupdate (the Dependency Vulnerability Scan stage, when the
# pod template sets DEPENDENCY_CHECK_DATA). Runs nightly as the
# dependency-check-db-update Jenkins job; the pipeline harness stage runs it
# before its build.
#
# Usage: scripts/dependency-check-db-update.sh DATA_DIR
#   NVD_API_KEY  required, activated (NVD answers 404 to keys it does not
#                accept). Keyless updates are not possible: dependency-check's
#                data-feed mode needs NVD's "modified" feed, which NVD no
#                longer publishes.
#
# The first run downloads every year of NVD data (several hundred MB, 10+
# minutes); later runs only fetch what changed.
set -euo pipefail

data=${1:?usage: dependency-check-db-update.sh DATA_DIR}
NVD_API="https://services.nvd.nist.gov/rest/json/cves/2.0"

mkdir -p "$data"
[ -n "${NVD_API_KEY:-}" ] || { echo "NVD_API_KEY is not set" >&2; exit 1; }
# dependency-check retries a key NVD rejects for a long time, so ask first;
# a key that is unknown or not yet activated gets a 404.
status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -H "apiKey: $NVD_API_KEY" "$NVD_API?resultsPerPage=1" || true)
case $status in
  200) ;;
  404) echo "NVD rejected NVD_API_KEY (404 Invalid apiKey): is it activated (link in NVD's email)?" >&2; exit 1 ;;
  *) echo "NVD API answered HTTP $status to a test request" >&2; exit 1 ;;
esac
exec dependency-check.sh --updateonly --data "$data" --nvdApiKey "$NVD_API_KEY"
