#!/usr/bin/env bash
# Linux prod release (local or Docker on macOS). QUIC steps match Dockerfile:
# sync-quic-deps, patch-quic, drop stale quic beams, verify-release-quic.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# HTTP/3 needs patched vendored quic + Cowboy QUIC hooks in release builds.
COWBOY_QUICER="${COWBOY_QUICER:-1}"
COWBOY_QUIC="${COWBOY_QUIC:-1}"
ERLANG_BUILD_IMAGE="${ERLANG_BUILD_IMAGE:-erlang:27}"

prepare_and_release() {
  cd "$ROOT_DIR"
  # Never reuse host _build/ in Docker (macOS beams break relx xref on Linux). Same as Dockerfile.
  rm -rf _build deps
  bash scripts/sync-quic-deps.sh
  rebar3 get-deps
  bash scripts/patch-ekub.sh
  bash scripts/patch-quic.sh
  bash scripts/verify-deps.sh "$ROOT_DIR"
  COWBOY_QUICER="$COWBOY_QUICER" COWBOY_QUIC="$COWBOY_QUIC" rebar3 as prod release
  bash scripts/verify-release-quic.sh "$ROOT_DIR"
}

build_local() {
  prepare_and_release
}

build_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required to build a Linux release on $(uname -s)." >&2
    exit 1
  fi

  docker run --rm \
    -v "$ROOT_DIR:/src" \
    -w /src \
    -e COWBOY_QUICER="$COWBOY_QUICER" \
    -e COWBOY_QUIC="$COWBOY_QUIC" \
    "$ERLANG_BUILD_IMAGE" \
    bash -lc '
      set -euo pipefail
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        bash git build-essential cmake ninja-build perl patch libssl-dev libncurses-dev
      export COWBOY_QUICER="'"$COWBOY_QUICER"'"
      export COWBOY_QUIC="'"$COWBOY_QUIC"'"
      bash scripts/build-release-linux.sh docker-inner
    '
}

if [ "${1:-}" = "docker-inner" ]; then
  prepare_and_release
  exit 0
fi

case "$(uname -s)" in
  Linux)
    build_local
    ;;
  *)
    build_docker
    ;;
esac