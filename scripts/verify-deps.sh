#!/bin/sh
set -e
ROOT="${1:-.}"
EKUB_SRC=$(find "${ROOT}/_build" -path '*/ekub/src/ekub_core.erl' 2>/dev/null | head -1)
QUIC_SRC="${ROOT}/deps/quic/src/qpack/quic_qpack.erl"
[ -f "$EKUB_SRC" ] || { echo "verify-deps: ekub not fetched" >&2; exit 1; }
[ -f "$QUIC_SRC" ] || { echo "verify-deps: deps/quic missing (run sync-quic-deps.sh)" >&2; exit 1; }
grep -q fail_if_no_peer_cert "$EKUB_SRC" && { echo "verify-deps: ekub not patched" >&2; exit 1; }
grep -q '0 -> 16#00' "$QUIC_SRC" || { echo "verify-deps: quic QPACK patch missing" >&2; exit 1; }
echo "verify-deps: ok"
