#!/usr/bin/env bash
# Fix root-owned artifacts from Dockerized release/package builds on self-hosted runners.
set -euo pipefail

ROOT="${1:-${GITHUB_WORKSPACE:-.}}"
cd "$ROOT"

paths=(_build deps _release_export release)
if [ "$(id -u)" -eq 0 ]; then
  rm -rf "${paths[@]}" 2>/dev/null || true
  exit 0
fi

if sudo -n true 2>/dev/null; then
  for p in "${paths[@]}"; do
    [ -e "$p" ] || continue
    sudo chown -R "$(id -u):$(id -g)" "$p" 2>/dev/null || true
    sudo rm -rf "$p" 2>/dev/null || true
  done
else
  rm -rf _release_export 2>/dev/null || true
fi
