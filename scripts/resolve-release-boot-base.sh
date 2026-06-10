#!/usr/bin/env bash
# Print boot basename for relx -boot (OTP 27: pertisk_eproxy.boot, OTP 29+: start.boot).
set -euo pipefail

REL_DIR="${1:?usage: resolve-release-boot-base.sh /path/to/releases/VSN}"

if [ -f "${REL_DIR}/pertisk_eproxy.boot" ]; then
  echo pertisk_eproxy
elif [ -f "${REL_DIR}/start.boot" ]; then
  echo start
else
  echo "resolve-release-boot-base: no boot file in ${REL_DIR}" >&2
  ls -la "${REL_DIR}" 2>/dev/null >&2 || true
  exit 1
fi
