#!/usr/bin/env bash
set -euo pipefail

REL_ROOT="${1:?usage: verify-release-runtime-abi.sh /path/to/release}"
MAX_GLIBC="${RPM_MAX_GLIBC:-2.34}"
MAX_GLIBCXX="${RPM_MAX_GLIBCXX:-3.4.29}"

find_required_version() {
  local bin_path="$1"
  local pattern="$2"

  strings "$bin_path" \
    | rg -o "$pattern" \
    | sed 's/^[^_]*_//' \
    | sort -V \
    | tail -n1
}

check_bin() {
  local bin_path="$1"
  local found_glibc found_glibcxx

  [ -f "$bin_path" ] || return 0

  found_glibc="$(find_required_version "$bin_path" 'GLIBC_[0-9]+\.[0-9]+' || true)"
  found_glibcxx="$(find_required_version "$bin_path" 'GLIBCXX_[0-9]+\.[0-9]+\.[0-9]+' || true)"

  if [ -n "$found_glibc" ] && [ "$(printf '%s\n%s\n' "$MAX_GLIBC" "$found_glibc" | sort -V | tail -n1)" != "$MAX_GLIBC" ]; then
    echo "RPM runtime ABI check failed: $(basename "$bin_path") requires GLIBC_${found_glibc}, max allowed is GLIBC_${MAX_GLIBC}." >&2
    echo "Rebuild with an older release image, for example:" >&2
    echo "  RPM_RELEASE_BUILD_IMAGE=hexpm/erlang:27.0.1-debian-bullseye-20240701-slim make package-rpm-amd64 VERSION=${VERSION:-<version>}" >&2
    return 1
  fi

  if [ -n "$found_glibcxx" ] && [ "$(printf '%s\n%s\n' "$MAX_GLIBCXX" "$found_glibcxx" | sort -V | tail -n1)" != "$MAX_GLIBCXX" ]; then
    echo "RPM runtime ABI check failed: $(basename "$bin_path") requires GLIBCXX_${found_glibcxx}, max allowed is GLIBCXX_${MAX_GLIBCXX}." >&2
    echo "Rebuild with an older release image, for example:" >&2
    echo "  RPM_RELEASE_BUILD_IMAGE=hexpm/erlang:27.0.1-debian-bullseye-20240701-slim make package-rpm-amd64 VERSION=${VERSION:-<version>}" >&2
    return 1
  fi
}

check_bin "$REL_ROOT"/erts-*/bin/beam.smp
check_bin "$REL_ROOT"/erts-*/bin/epmd

echo "verify-release-runtime-abi: ok (GLIBC <= ${MAX_GLIBC}, GLIBCXX <= ${MAX_GLIBCXX})"