#!/usr/bin/env bash
# Copy runtime shared libraries needed by release executables on older hosts.
set -euo pipefail

DEST_ROOT="${1:?usage: bundle-runtime-libs-for-rpm.sh /path/to/pkg/opt/pertisk-eproxy}"
ERLANG_IMAGE="${ERLANG_BUILD_IMAGE:-erlang:29}"
ERLANG_BUILD_PLATFORM="${ERLANG_BUILD_PLATFORM:-}"
OUT_DIR="${DEST_ROOT}/lib/runtime"
PLATFORM_OPT=()
if [ -n "$ERLANG_BUILD_PLATFORM" ]; then
  PLATFORM_OPT=(--platform "$ERLANG_BUILD_PLATFORM")
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "bundle-runtime-libs-for-rpm: docker required" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "${OUT_DIR}"/libgcc_s.so* "${OUT_DIR}"/libtinfo.so* "${OUT_DIR}"/libncursesw.so* 2>/dev/null || true

echo "bundle-runtime-libs-for-rpm: copying libs from ${ERLANG_IMAGE} -> ${OUT_DIR}"
docker run --rm \
  ${PLATFORM_OPT[@]+"${PLATFORM_OPT[@]}"} \
  -v "${OUT_DIR}:/out:rw" \
  "${ERLANG_IMAGE}" \
  bash -lc '
    set -euo pipefail
    shopt -s nullglob
    copied=0
    for dir in /usr/lib /lib /usr/lib64 /lib64 /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu; do
      [ -d "$dir" ] || continue
      for pat in libgcc_s.so.1 libtinfo.so.6 libtinfo.so libncursesw.so.6; do
        for f in "$dir"/${pat}*; do
          [ -e "$f" ] || continue
          cp -a "$f" /out/
          copied=1
        done
      done
    done
    if [ "$copied" -eq 0 ]; then
      echo "bundle-runtime-libs-for-rpm: no runtime libs found in image" >&2
      exit 1
    fi
    ls -la /out
  '

echo "bundle-runtime-libs-for-rpm: ok"