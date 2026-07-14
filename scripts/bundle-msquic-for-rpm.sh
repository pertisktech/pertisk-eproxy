#!/usr/bin/env bash
# Copy quicer / MsQuic shared libraries from the packaged release into lib/runtime
# so systemd LD_LIBRARY_PATH can load the NIF on older hosts.
set -euo pipefail

DEST_ROOT="${1:?usage: bundle-msquic-for-rpm.sh /path/to/pkg/opt/pertisk-eproxy}"
OUT_DIR="$(cd "${DEST_ROOT}" && pwd)/lib/runtime"
LIB_DIR="$(cd "${DEST_ROOT}" && pwd)/lib"

mkdir -p "$OUT_DIR"

copied=0
while IFS= read -r -d '' f; do
  cp -a "$f" "$OUT_DIR/"
  copied=1
done < <(find "$LIB_DIR" -type f \( \
  -name 'libmsquic*.so*' \
  -o -name 'libquicer*.so*' \
  -o -path '*/quicer-*/priv/*.so' \
  -o -path '*/quicer-*/priv/*/*.so' \
\) -print0 2>/dev/null)

if [ "$copied" -eq 0 ]; then
  echo "bundle-msquic-for-rpm: warning: no msquic/quicer .so found under ${LIB_DIR}" >&2
  echo "bundle-msquic-for-rpm: release may still work if NIF is statically linked" >&2
  exit 0
fi

echo "bundle-msquic-for-rpm: copied native libs -> ${OUT_DIR}"
ls -la "$OUT_DIR"/libmsquic* "$OUT_DIR"/*.so 2>/dev/null || ls -la "$OUT_DIR" | head -40
echo "bundle-msquic-for-rpm: ok"
