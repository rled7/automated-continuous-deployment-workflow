#!/bin/sh
# Prints $NVD_API_KEY in the form NVD accepts: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX.
# Secret stores get the key pasted in whatever shape it was copied in, and NVD
# answers 404 to anything else, so: spaces and line breaks are dropped, and a
# key pasted without its hyphens gets them back. Anything else is printed as
# given, for NVD to judge.
#
# The result can differ from the stored secret, and Jenkins masks only the
# stored value: keep shell tracing (set -x) off wherever it is expanded.
printf '%s' "${NVD_API_KEY:?NVD_API_KEY is not set}" | tr -d '[:space:]' |
  sed -E 's/^([0-9A-Fa-f]{8})([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})([0-9A-Fa-f]{12})$/\1-\2-\3-\4-\5/'
