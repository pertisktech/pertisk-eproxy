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
QUIC_VSN=$(sed -n 's/.*{vsn, "\([^"]*\)"}.*/\1/p' "$QUIC_APP" | head -1)
case "$QUIC_VSN" in
	1.4.*)
		: ;;
	*)
		echo "verify-deps: expected erlang_quic 1.4.x" >&2
		exit 1
		;;
esac

case "$QUIC_VSN" in
	1.4.3|1.4.[4-9]*|1.[5-9]*|[2-9].*)
		# QPACK RFC9204 prefix fix is upstream in 1.4.3+.
		: ;;
	*)
		grep -q '0 -> 16#00' "$QUIC_QPACK" || {
			echo "verify-deps: quic QPACK compatibility patch missing (required for $QUIC_VSN)" >&2
			exit 1
		}
		;;
esac
echo "verify-deps: ok"
