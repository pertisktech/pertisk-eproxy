#!/usr/bin/env bash
# Copy the OpenSSL libs required by the Erlang crypto NIF from the release build image.
set -euo pipefail

DEST_ROOT="${1:?usage: bundle-openssl-for-rpm.sh /path/to/pkg/opt/pertisk-eproxy}"
ERLANG_IMAGE="${ERLANG_BUILD_IMAGE:-erlang:29}"
ERLANG_BUILD_PLATFORM="${ERLANG_BUILD_PLATFORM:-}"
OUT_DIR="$(cd "${DEST_ROOT}" && pwd)/lib/openssl"
PLATFORM_OPT=()
if [ -n "$ERLANG_BUILD_PLATFORM" ]; then
  PLATFORM_OPT=(--platform "$ERLANG_BUILD_PLATFORM")
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "bundle-openssl-for-rpm: docker required" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "${OUT_DIR}"/libcrypto.so* "${OUT_DIR}"/libssl.so* 2>/dev/null || true

echo "bundle-openssl-for-rpm: copying libs from ${ERLANG_IMAGE} -> ${OUT_DIR}"
docker run --rm \
  ${PLATFORM_OPT[@]+"${PLATFORM_OPT[@]}"} \
  -v "${OUT_DIR}:/out:rw" \
  "${ERLANG_IMAGE}" \
  bash -lc '
    set -euo pipefail
    shopt -s nullglob
    mapfile -t crypto_libs < <(
      ldd /usr/local/lib/erlang/lib/crypto-*/priv/lib/crypto.so 2>/dev/null \
        | awk "/lib(crypto|ssl)\\.so/ { print \$1 }" \
        | sort -u
    )
    if [ "${#crypto_libs[@]}" -eq 0 ]; then
      for fallback in libcrypto.so.3 libssl.so.3 libcrypto.so.1.1 libssl.so.1.1; do
        for dir in /usr/lib /lib /usr/lib64 /lib64 /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu; do
          [ -d "$dir" ] || continue
          if [ -e "$dir/$fallback" ]; then
            crypto_libs+=("$fallback")
            break
          fi
        done
      done
    fi
    if [ "${#crypto_libs[@]}" -eq 0 ]; then
      echo "bundle-openssl-for-rpm: no OpenSSL runtime libs found in image" >&2
      exit 1
    fi
    copied=0
    for dir in /usr/lib /lib /usr/lib64 /lib64 /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu; do
      [ -d "$dir" ] || continue
      for pat in "${crypto_libs[@]}"; do
        for f in "$dir"/${pat}*; do
          [ -e "$f" ] || continue
          cp -a "$f" /out/
          copied=1
        done
      done
    done
    if [ "$copied" -eq 0 ]; then
      echo "bundle-openssl-for-rpm: failed to copy required libs: ${crypto_libs[*]}" >&2
      exit 1
    fi
    ls -la /out
  '

echo "bundle-openssl-for-rpm: ok"
