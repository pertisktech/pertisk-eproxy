#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COWBOY_QUICER="${COWBOY_QUICER:-0}"
COWBOY_QUIC="${COWBOY_QUIC:-0}"
RELEASE_BUILD_IMAGE="${RELEASE_BUILD_IMAGE:-erlang:27}"
RELEASE_BUILD_PLATFORM="${RELEASE_BUILD_PLATFORM:-linux/amd64}"
RELEASE_BUILD_FORCE_DOCKER="${RELEASE_BUILD_FORCE_DOCKER:-0}"

build_local() {
  cd "$ROOT_DIR"
  COWBOY_QUICER="$COWBOY_QUICER" COWBOY_QUIC="$COWBOY_QUIC" rebar3 as prod release
}

local_runtime_ok() {
  if ! command -v erl >/dev/null 2>&1 || ! command -v rebar3 >/dev/null 2>&1; then
    return 1
  fi

  erl -noshell -eval '
    HasNifError = erlang:function_exported(erlang, nif_error, 1),
    ZlibOk =
      case catch zlib:compress(<<"ok">>) of
        Bin when is_binary(Bin) -> true;
        _ -> false
      end,
    case HasNifError andalso ZlibOk of
      true -> init:stop(0);
      false -> init:stop(1)
    end.
  ' >/dev/null 2>&1
}

build_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required to build a Linux release on $(uname -s)." >&2
    exit 1
  fi

  mkdir -p "$ROOT_DIR/_build/prod/rel"

  docker run --rm \
    --platform "$RELEASE_BUILD_PLATFORM" \
    -v "$ROOT_DIR:/src" \
    -e COWBOY_QUICER="$COWBOY_QUICER" \
    -e COWBOY_QUIC="$COWBOY_QUIC" \
    "$RELEASE_BUILD_IMAGE" \
    bash -lc '
      set -euo pipefail
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y bash git build-essential cmake ninja-build perl libssl-dev libncurses-dev rsync

      rm -rf /tmp/eproxy-build
      mkdir -p /tmp/eproxy-build
      rsync -a --delete --exclude _build /src/ /tmp/eproxy-build/

      cd /tmp/eproxy-build
      rm -rf _build
      rebar3 as prod release

      rm -rf /src/_build/prod/rel/pertisk_eproxy
      cp -a /tmp/eproxy-build/_build/prod/rel/pertisk_eproxy /src/_build/prod/rel/
    '
}

case "$(uname -s)" in
  Linux)
    if [[ "$RELEASE_BUILD_FORCE_DOCKER" == "1" ]]; then
      build_docker
    elif local_runtime_ok; then
      build_local
    else
      echo "Local Erlang runtime check failed; falling back to Docker build." >&2
      echo "Set RELEASE_BUILD_FORCE_DOCKER=1 to always build in Docker." >&2
      build_docker
    fi
    ;;
  *)
    build_docker
    ;;
esac