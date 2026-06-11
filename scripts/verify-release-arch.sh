#!/usr/bin/env bash
# Fail fast when a release ERTS binary does not match the package target arch.
set -euo pipefail

REL_DIR="${1:?usage: verify-release-arch.sh /path/to/rel/pertisk_eproxy [x86_64|aarch64]}"
WANT_ARCH="${2:-x86_64}"

find_erlexec() {
  find "$1" -path '*/erts-*/bin/erlexec' -type f 2>/dev/null | head -1
}

ERLEXEC="$(find_erlexec "$REL_DIR")"
if [ -z "$ERLEXEC" ]; then
  echo "verify-release-arch: erlexec not found under $REL_DIR" >&2
  exit 1
fi

if ! command -v file >/dev/null 2>&1; then
  echo "verify-release-arch: skipping (file(1) not available)" >&2
  exit 0
fi

INFO="$(file -b "$ERLEXEC")"
case "$WANT_ARCH" in
  x86_64|amd64)
    if echo "$INFO" | grep -qE 'x86-64|80386'; then
      echo "verify-release-arch: ok ($ERLEXEC)"
      exit 0
    fi
    HINT="RELEASE_BUILD_PLATFORM=linux/amd64 make release"
    ;;
  aarch64|arm64)
    if echo "$INFO" | grep -qiE 'aarch64|ARM'; then
      echo "verify-release-arch: ok ($ERLEXEC)"
      exit 0
    fi
    HINT="RELEASE_BUILD_PLATFORM=linux/arm64 make release"
    ;;
  *)
    echo "verify-release-arch: unsupported arch $WANT_ARCH" >&2
    exit 1
    ;;
esac

echo "verify-release-arch: expected ${WANT_ARCH} ELF for $ERLEXEC, got: $INFO" >&2
echo "verify-release-arch: rebuild with: $HINT" >&2
exit 1
