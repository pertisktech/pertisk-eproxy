#!/bin/sh
# Apply QUIC/QPACK interop fix for static-only header blocks (RIC=0 -> Base sign bit 0).
set -e
ROOT="${REBAR_ROOT_DIR:-.}"
found=0

for f in $(find "${ROOT}/_build" -path '*/quic/src/qpack/quic_qpack.erl' 2>/dev/null | sort -u); do
  found=1

  if grep -q '0 -> 16#00' "$f"; then
    continue
  fi

  perl -i -0pe '
    s/BaseEncoded = 16#80,/BaseEncoded =\n        case RIC of\n            0 -> 16#00;\n            _ -> 16#80\n        end,/s
  ' "$f"

  rm -f "$(dirname "$f")/../../ebin/quic_qpack.beam" 2>/dev/null || true

done

if [ "$found" -eq 0 ]; then
  echo "patch-quic: no quic_qpack.erl under _build (run rebar3 get-deps first)" >&2
  exit 1
fi

QPACK=$(find "${ROOT}/_build" -path '*/quic/src/qpack/quic_qpack.erl' 2>/dev/null | head -1)
grep -q '0 -> 16#00' "$QPACK" || {
  echo "patch-quic: QPACK patch missing in $QPACK" >&2
  exit 1
}

echo "patch-quic: ok"
