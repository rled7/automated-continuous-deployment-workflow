#!/usr/bin/env bash
# Bring dependency-check's vulnerability database up to date, for builds that
# then scan with --noupdate (the Dependency Vulnerability Scan stage, when the
# pod template sets DEPENDENCY_CHECK_DATA). Runs nightly as the
# dependency-check-db-update Jenkins job; the pipeline harness stage runs it
# before its build.
#
# Usage: scripts/dependency-check-db-update.sh DATA_DIR
#   NVD_API_KEY  required, activated (NVD answers 404 to keys it does not
#                accept); with or without its hyphens (scripts/nvd-api-key.sh). Keyless updates are not possible: dependency-check's
#                data-feed mode needs NVD's "modified" feed, which NVD no
#                longer publishes.
#
# The first run downloads every year of NVD data (several hundred MB, 10+
# minutes); later runs only fetch what changed.
#
# DATA_DIR/update-complete holds the time (Unix seconds) of the last update
# that finished. It is removed when an update starts, so a database left
# half-downloaded by a failed or interrupted update has none, and the
# Dependency Vulnerability Scan refuses to scan with it.
set -euo pipefail

data=${1:?usage: dependency-check-db-update.sh DATA_DIR}
NVD_API="https://services.nvd.nist.gov/rest/json/cves/2.0"

mkdir -p "$data"
[ -n "${NVD_API_KEY:-}" ] || { echo "NVD_API_KEY is not set" >&2; exit 1; }
NVD_API_KEY=$("$(dirname "$0")/nvd-api-key.sh")
# dependency-check retries a key NVD rejects for a long time, so ask first;
# a key that is unknown or not yet activated gets a 404.
status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -H "apiKey: $NVD_API_KEY" "$NVD_API?resultsPerPage=1" || true)
case $status in
  200) ;;
  404)
    # Describe the value without printing it.
    shape="${#NVD_API_KEY} characters"
    if [[ $NVD_API_KEY =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
      shape+=", shaped like an NVD key: NVD does not know it. It is another value of the same shape (the"
      shape+=" request ID on NVD's pages looks the same), or a key not activated yet"
    else
      shape+=", not shaped like an NVD key (32 hexadecimal digits, hyphens optional)"
    fi
    echo "NVD rejected NVD_API_KEY (404 Invalid apiKey). The value is $shape." >&2
    echo "Use the key the NVD activation page shows." >&2
    exit 1 ;;
  *) echo "NVD API answered HTTP $status to a test request" >&2; exit 1 ;;
esac
rm -f "$data/update-complete"
dependency-check.sh --updateonly --data "$data" --nvdApiKey "$NVD_API_KEY"
date -u +%s > "$data/update-complete"
