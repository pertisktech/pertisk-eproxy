#!/usr/bin/env bash
# Linux prod release (local or Docker on macOS).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# HTTP/3 release builds with Cowboy QUIC hooks enabled.
COWBOY_QUICER="${COWBOY_QUICER:-1}"
COWBOY_QUIC="${COWBOY_QUIC:-1}"
ERLANG_BUILD_IMAGE="${ERLANG_BUILD_IMAGE:-erlang:27}"
RELEASE_BUILD_FORCE_DOCKER="${RELEASE_BUILD_FORCE_DOCKER:-0}"
RELEASE_BUILD_PLATFORM="${RELEASE_BUILD_PLATFORM:-}"

prepare_and_release() {
  cd "$ROOT_DIR"
  # Never reuse host _build/ in Docker (macOS beams break relx xref on Linux). Same as docker/Dockerfile.proxy.
  rm -rf _build deps
  rebar3 get-deps
  bash scripts/patch-ekub.sh
  bash scripts/patch-quic.sh
  bash scripts/patch-hackney.sh
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

  if [ -n "$RELEASE_BUILD_PLATFORM" ]; then
    echo "Using Docker platform: $RELEASE_BUILD_PLATFORM"
    docker run --rm \
      --platform "$RELEASE_BUILD_PLATFORM" \
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
  else
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
  fi
}

if [ "${1:-}" = "docker-inner" ]; then
  prepare_and_release
  exit 0
fi

if [ "$RELEASE_BUILD_FORCE_DOCKER" = "1" ]; then
  echo "RELEASE_BUILD_FORCE_DOCKER=1 set: building release in Docker"
  build_docker
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