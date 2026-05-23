#!/bin/sh
# Fail the image build if compiled quic_qpack does not encode RIC=0 correctly.
set -e
ROOT="${1:-.}"
ERTS=$(command -v erl 2>/dev/null || true)
[ -z "$ERTS" ] && ERTS=$(find "${ROOT}/_build" -path '*/erts-*/bin/erl' 2>/dev/null | head -1)
[ -n "$ERTS" ] || {
  echo "verify-release-quic: erl not found" >&2
  exit 1
}

check_ebin() {
  QUIC_EBIN="$1"
  "${ERTS}" -noshell -pa "${QUIC_EBIN}" -eval '
    case quic_qpack:encode([{<<":status">>, <<"200">>}]) of
        <<0,0,_/binary>> -> halt(0);
        Enc -> io:format(standard_error, "bad qpack prefix: ~p~n", [Enc]), halt(2)
    end.
' || return 1
  return 0
}

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

FAILED=0
for QUIC_EBIN in $(find "${ROOT}/_build" -path '*/quic/ebin' -type d 2>/dev/null | sort -u); do
  if check_ebin "${QUIC_EBIN}"; then
    echo "verify-release-quic: ok (${QUIC_EBIN})"
  else
    echo "verify-release-quic: failed (${QUIC_EBIN})" >&2
    FAILED=1
  fi
done

REL_LIB="${ROOT}/_build/prod/rel/pertisk_eproxy/lib"
if [ -d "${REL_LIB}" ]; then
  for QUIC_EBIN in "${REL_LIB}"/quic-*/ebin; do
    [ -d "${QUIC_EBIN}" ] || continue
    if check_ebin "${QUIC_EBIN}"; then
      echo "verify-release-quic: ok (release ${QUIC_EBIN})"
    else
      echo "verify-release-quic: release beam failed (${QUIC_EBIN})" >&2
      FAILED=1
    fi
  done
fi

if [ "$FAILED" -ne 0 ]; then
  echo "verify-release-quic: quic_qpack RIC=0 check failed" >&2
  exit 1
fi

if ! find "${ROOT}/_build" -path '*/quic/ebin' -type d 2>/dev/null | grep -q .; then
  echo "verify-release-quic: quic ebin not found under _build" >&2
  exit 1
fi

echo "verify-release-quic: all checks passed"
