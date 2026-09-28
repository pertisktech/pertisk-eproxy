#!/usr/bin/env bash
# Ensure native deps for emqx/quicer (MsQuic) NIF builds on self-hosted CI.
# Without libatomic, CMake sets ATOMIC=NOTFOUND and `make build-nif` fails.
set -euo pipefail

have_libatomic() {
  # CMake: find_library(ATOMIC NAMES atomic libatomic.so.1)
  ldconfig -p 2>/dev/null | grep -qE 'libatomic\.so(\.1)?\b' && return 0
  for f in \
    /usr/lib64/libatomic.so \
    /usr/lib64/libatomic.so.1 \
    /usr/lib/x86_64-linux-gnu/libatomic.so \
    /usr/lib/x86_64-linux-gnu/libatomic.so.1 \
    /usr/lib/aarch64-linux-gnu/libatomic.so \
    /usr/lib/aarch64-linux-gnu/libatomic.so.1 \
    /lib64/libatomic.so.1 \
    /lib/x86_64-linux-gnu/libatomic.so.1; do
    [ -e "$f" ] && return 0
  done
  return 1
}

have_numa_headers() {
  [ -f /usr/include/numa.h ] || [ -f /usr/include/numa/numa.h ]
}

run_pkg() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n "$@"
  else
    return 1
  fi
}

ensure_libatomic_so_symlink() {
  # Alma/RHEL libatomic often ships only libatomic.so.1; CMake looks for -latomic.
  local so so1
  for so1 in /usr/lib64/libatomic.so.1 /usr/lib/libatomic.so.1; do
    so="${so1%.1}"
    if [ -e "$so1" ] && [ ! -e "$so" ]; then
      if run_pkg ln -s "$(basename "$so1")" "$so" 2>/dev/null; then
        echo "created $so -> $(basename "$so1")" >&2
      fi
    fi
  done
}

try_install() {
  if command -v dnf >/dev/null 2>&1; then
    echo "Installing quicer build deps via dnf: libatomic numactl-devel" >&2
    run_pkg dnf install -y libatomic numactl-devel cmake gcc-c++ make perl
  elif command -v yum >/dev/null 2>&1; then
    echo "Installing quicer build deps via yum: libatomic numactl-devel" >&2
    run_pkg yum install -y libatomic numactl-devel cmake gcc-c++ make perl
  elif command -v apt-get >/dev/null 2>&1; then
    echo "Installing quicer build deps via apt: libatomic1 libnuma-dev" >&2
    run_pkg apt-get update -qq
    run_pkg apt-get install -y -qq libatomic1 libnuma-dev cmake g++ make perl
  else
    return 1
  fi
  ensure_libatomic_so_symlink
}

need_install=0
if ! have_libatomic; then
  echo "libatomic not found (required for quicer/msquic NIF)" >&2
  need_install=1
fi
if ! have_numa_headers; then
  echo "numa.h not found (recommended for quicer/msquic; libnuma.so alone is not enough)" >&2
  need_install=1
fi

if [ "$need_install" -eq 1 ]; then
  if try_install; then
    if command -v ldconfig >/dev/null 2>&1; then
      run_pkg ldconfig || true
    fi
  else
    echo "Could not auto-install packages (need root or passwordless sudo)." >&2
  fi
fi

if ! have_libatomic; then
  cat >&2 <<'EOF'
ci-ensure-quicer-build-deps: libatomic still missing.

quicer's CMake links ATOMIC; without it you get:
  CMake Error: ATOMIC ... set to NOTFOUND
  make: *** [Makefile:20: build-nif] Error 1

Install on the AlmaLinux self-hosted runner (as root), then re-run CI:
  dnf install -y libatomic numactl-devel
  # Alma ships libatomic.so.1 only; CMake needs libatomic.so for -latomic:
  [ -e /usr/lib64/libatomic.so ] || ln -s libatomic.so.1 /usr/lib64/libatomic.so
  ldconfig
EOF
  exit 1
fi

ensure_libatomic_so_symlink

if have_numa_headers; then
  echo "quicer build deps: libatomic ok, numa.h ok"
else
  echo "quicer build deps: libatomic ok (numa.h still missing; build may warn)"
fi
