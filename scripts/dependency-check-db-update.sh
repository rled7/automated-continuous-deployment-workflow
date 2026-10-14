#!/usr/bin/env bash
# Bring dependency-check's vulnerability database up to date, for builds that
# then scan with --noupdate (the Dependency Vulnerability Scan stage, when the
# pod template sets DEPENDENCY_CHECK_DATA). Runs nightly as the
# dependency-check-db-update Jenkins job; the pipeline harness stage runs it
# before its build.
#
# Usage: scripts/dependency-check-db-update.sh DATA_DIR
#   NVD_API_KEY  optional. Used when NVD accepts it (incremental updates
#                through the NVD API); otherwise the database is built from
#                NVD's public data feeds, which need no key.
#
# The first run downloads every year of NVD data (several hundred MB, 10+
# minutes); later runs only fetch what changed.
set -euo pipefail

data=${1:?usage: dependency-check-db-update.sh DATA_DIR}
NVD_API="https://services.nvd.nist.gov/rest/json/cves/2.0"
NVD_FEED="https://nvd.nist.gov/feeds/json/cve/2.0/nvdcve-2.0-{0}.json.gz"

mkdir -p "$data"
# dependency-check retries a key NVD rejects for a long time, so ask first;
# a key that is unknown or not yet activated gets a 404.
status=""
if [ -n "${NVD_API_KEY:-}" ]; then
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -H "apiKey: $NVD_API_KEY" "$NVD_API?resultsPerPage=1" || true)
fi
if [ "$status" = 200 ]; then
  echo "updating from the NVD API"
  set -- --nvdApiKey "$NVD_API_KEY"
else
  case $status in
    "") echo "no NVD_API_KEY: updating from NVD's public data feeds" ;;
    404) echo "NVD rejected NVD_API_KEY (404 Invalid apiKey; activated?): updating from NVD's public data feeds" ;;
    *) echo "NVD API answered HTTP $status: updating from NVD's public data feeds" ;;
  esac
  set -- --nvdDatafeed "$NVD_FEED"
fi
exec dependency-check.sh --updateonly --data "$data" "$@"
