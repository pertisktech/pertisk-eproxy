#!/bin/sh
# Verify release still contains required local QUIC patches.
set -e
ROOT="${1:-.}"

REL_LIB="${ROOT}/_build/prod/rel/pertisk_eproxy/lib"
if [ ! -d "${REL_LIB}" ]; then
  echo "verify-release-quic: release lib missing at ${REL_LIB}" >&2
  exit 1
fi
REL_QUIC=$(find "${REL_LIB}" -maxdepth 1 -type d -name 'quic-*' 2>/dev/null | head -1)
if [ -z "${REL_QUIC}" ]; then
  echo "verify-release-quic: quic application not packaged in release (add quic to pertisk_eproxy.app.src)" >&2
  exit 1
fi

if ! find "${ROOT}/_build" -path '*/quic/ebin' -type d 2>/dev/null | grep -q .; then
  echo "verify-release-quic: quic ebin not found under _build" >&2
  exit 1
fi

H3_SRC=$(find "${ROOT}/_build" -path '*/quic/src/h3/quic_h3_connection.erl' 2>/dev/null | head -1)
if [ -n "${H3_SRC}" ]; then
  if grep -q 'next_event, cast, close' "${H3_SRC}"; then
    echo "verify-release-quic: illegal state_enter next_event found in ${H3_SRC}" >&2
    exit 1
  fi
  if ! grep -q 'catch open_critical_streams(State)' "${H3_SRC}"; then
    echo "verify-release-quic: missing h3 draining safety patch in ${H3_SRC}" >&2
    exit 1
  fi
fi

H3_API_SRC=$(find "${ROOT}/_build" -path '*/quic/src/h3/quic_h3.erl' 2>/dev/null | head -1)
if [ -n "${H3_API_SRC}" ]; then
  if ! grep -q 'maps:with(\[cert, key, cert_chain, private_key, cacerts, sni_certs\], Opts)' "${H3_API_SRC}"; then
    echo "verify-release-quic: missing h3 sni/tls opts passthrough patch in ${H3_API_SRC}" >&2
    exit 1
  fi
fi

CONN_SRC=$(find "${ROOT}/_build" -path '*/quic/src/quic_connection.erl' 2>/dev/null | head -1)
if [ -n "${CONN_SRC}" ]; then
  if ! grep -q 'maybe_apply_server_cert_for_sni' "${CONN_SRC}"; then
    echo "verify-release-quic: missing quic_connection SNI cert selection patch in ${CONN_SRC}" >&2
    exit 1
  fi
fi

echo "verify-release-quic: all checks passed"
