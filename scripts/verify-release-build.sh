#!/bin/sh
set -e
ROOT="${1:-.}"
REL="${ROOT}/_build/prod/rel/pertisk_eproxy"
[ -x "${REL}/bin/pertisk_eproxy" ] || {
  echo "verify-release-build: release missing at ${REL}" >&2
  exit 1
}
PEM=$(find "${REL}/lib" -path '*/priv/tls/listener.pem' 2>/dev/null | head -1)
[ -n "$PEM" ] || {
  echo "verify-release-build: listener.pem not in release priv" >&2
  exit 1
}
echo "verify-release-build: ok"
