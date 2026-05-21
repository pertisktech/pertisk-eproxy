#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COWBOY_QUICER="${COWBOY_QUICER:-0}"
COWBOY_QUIC="${COWBOY_QUIC:-0}"

build_local() {
  cd "$ROOT_DIR"
  COWBOY_QUICER="$COWBOY_QUICER" COWBOY_QUIC="$COWBOY_QUIC" rebar3 as prod release
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
    erlang:27-bookworm \
    sh -lc '
      set -euo pipefail
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y bash git build-essential cmake ninja-build perl libssl-dev libncurses-dev
      rm -rf _build
      rebar3 as prod release
    '
}

case "$(uname -s)" in
  Linux)
    build_local
    ;;
  *)
    build_docker
    ;;
esac