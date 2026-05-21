#!/bin/sh
# Ensure QPACK RIC=0 fix is present in every quic_qpack.erl used by the build.
set -e
ROOT="${REBAR_ROOT_DIR:-.}"
PATCH="${ROOT}/contrib/erlang_quic_upstream_patches/pertisk-vendor-quic-interop-v1.3.0.patch"
found=0
for f in $(find "${ROOT}" \( -path '*/quic/src/qpack/quic_qpack.erl' \) 2>/dev/null | sort -u); do
  found=1
  if grep -q '0 -> 16#00' "$f"; then
    continue
  fi
  dir=$(dirname "$f")/../..
  if [ -f "$PATCH" ] && patch -p1 -d "$dir" -N -i "$PATCH" 2>/dev/null; then
    :
  else
    perl -i -0pe '
      s/BaseEncoded = 16#80,/BaseEncoded =\n        case RIC of\n            0 -> 16#00;\n            _ -> 16#80\n        end,/s
    ' "$f" || exit 1
  fi
  rm -f "$(dirname "$f")/../../ebin/quic_qpack.beam" 2>/dev/null || true
done
if [ "$found" -eq 0 ]; then
  echo "patch-quic: no quic_qpack.erl found (run rebar3 get-deps first)" >&2
  exit 1
fi
QPACK=$(find "${ROOT}" -path '*/quic/src/qpack/quic_qpack.erl' | head -1)
grep -q '0 -> 16#00' "$QPACK" || {
  echo "patch-quic: QPACK patch missing in $QPACK" >&2
  exit 1
}
echo "patch-quic: ok"
