#!/usr/bin/env bash
# Copy OpenSSL 3.x libs from the Erlang release build image into the RPM tree.
# OTP 27 crypto NIF needs symbols (e.g. EVP_sm4_cbc) missing from older host libcrypto.
set -euo pipefail

DEST_ROOT="${1:?usage: bundle-openssl-for-rpm.sh /path/to/pkg/opt/pertisk-eproxy}"
ERLANG_IMAGE="${ERLANG_BUILD_IMAGE:-erlang:27}"
OUT_DIR="${DEST_ROOT}/lib/openssl"

if ! command -v docker >/dev/null 2>&1; then
  echo "bundle-openssl-for-rpm: docker required" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "${OUT_DIR}"/libcrypto.so* "${OUT_DIR}"/libssl.so* 2>/dev/null || true

echo "bundle-openssl-for-rpm: copying libs from ${ERLANG_IMAGE} -> ${OUT_DIR}"
docker run --rm \
  -v "${OUT_DIR}:/out:rw" \
  "${ERLANG_IMAGE}" \
  bash -lc '
    set -euo pipefail
    shopt -s nullglob
    copied=0
    for dir in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /lib64; do
      [ -d "$dir" ] || continue
      for pat in libcrypto.so.3 libssl.so.3; do
        for f in "$dir"/${pat}*; do
          [ -e "$f" ] || continue
          cp -a "$f" /out/
          copied=1
        done
      done
    done
    if [ "$copied" -eq 0 ]; then
      echo "bundle-openssl-for-rpm: no libcrypto.so.3 / libssl.so.3 in image" >&2
      exit 1
    fi
    ls -la /out
  '

echo "bundle-openssl-for-rpm: ok"
