#!/usr/bin/env bash
# Fix root-owned artifacts from Dockerized release/package builds on self-hosted runners.
set -u

ROOT="${1:-${GITHUB_WORKSPACE:-.}}"
cd "$ROOT"

paths=(_build deps _release_export release)

rm_paths_direct() {
  local p
  for p in "${paths[@]}"; do
    [ -e "$p" ] || continue
    rm -rf "$p" 2>/dev/null || true
  done
}

rm_paths_sudo() {
  local p
  for p in "${paths[@]}"; do
    [ -e "$p" ] || continue
    sudo chown -R "$(id -u):$(id -g)" "$p" 2>/dev/null || true
    sudo rm -rf "$p" 2>/dev/null || true
  done
}

rm_paths_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  docker run --rm -v "$ROOT:/work" alpine:3.20 \
    sh -c 'rm -rf /work/_build /work/deps /work/_release_export /work/release 2>/dev/null; exit 0'
}

if [ "$(id -u)" -eq 0 ]; then
  rm_paths_direct
  exit 0
fi

if sudo -n true 2>/dev/null; then
  rm_paths_sudo
elif rm_paths_docker; then
  :
else
  rm_paths_direct
fi
