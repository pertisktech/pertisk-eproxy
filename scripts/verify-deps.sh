#!/bin/sh
set -e
ROOT="${1:-.}"
EKUB_SRC=$(find "${ROOT}/_build" -path '*/ekub/src/ekub_core.erl' 2>/dev/null | head -1)
QUIC_APP=$(find "${ROOT}/_build" -path '*/quic/src/quic.app.src' 2>/dev/null | head -1)
QUIC_QPACK=$(find "${ROOT}/_build" -path '*/quic/src/qpack/quic_qpack.erl' 2>/dev/null | head -1)
[ -f "$EKUB_SRC" ] || { echo "verify-deps: ekub not fetched" >&2; exit 1; }
[ -f "$QUIC_APP" ] || { echo "verify-deps: quic not fetched" >&2; exit 1; }
[ -f "$QUIC_QPACK" ] || { echo "verify-deps: quic_qpack source missing" >&2; exit 1; }
grep -q fail_if_no_peer_cert "$EKUB_SRC" && { echo "verify-deps: ekub not patched" >&2; exit 1; }
grep -q '{vsn, "1.4.0"}' "$QUIC_APP" || {
	echo "verify-deps: expected erlang_quic 1.4.0" >&2
	exit 1
}
grep -q '0 -> 16#00' "$QUIC_QPACK" || {
	echo "verify-deps: quic QPACK compatibility patch missing" >&2
	exit 1
}
echo "verify-deps: ok"
