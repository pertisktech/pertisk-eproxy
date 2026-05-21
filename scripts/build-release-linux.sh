#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COWBOY_QUICER="${COWBOY_QUICER:-0}"
COWBOY_QUIC="${COWBOY_QUIC:-0}"
# Override to use a different base image (e.g. almalinux:9 for RPM targets).
ERLANG_DOCKER_IMAGE="${ERLANG_DOCKER_IMAGE:-erlang:27}"
FORCE_DOCKER_RELEASE="${FORCE_DOCKER_RELEASE:-0}"
TARGET_OPENSSL_ABI="${TARGET_OPENSSL_ABI:-}"

validate_qpack_chrome_compat() {
  local REL_DIR ERL_BIN
  REL_DIR="$ROOT_DIR/_build/prod/rel/pertisk_eproxy"
  ERL_BIN="$(echo "$REL_DIR"/erts-*/bin/erl)"
  if [ ! -x "$ERL_BIN" ]; then
    echo "Release validation failed: erl not found in $REL_DIR/erts-*/bin/erl" >&2
    return 1
  fi

  "$ERL_BIN" -pa "$REL_DIR"/lib/*/ebin -noshell -eval '
    case quic_qpack:encode([{<<":status">>, <<"200">>}]) of
      <<0,0,_/binary>> ->
        io:format("qpack_check=ok~n"),
        init:stop(0);
      Encoded ->
        io:format("qpack_check=bad encoded=~p~n", [Encoded]),
        init:stop(42)
    end.
  '
}

detect_openssl_abi() {
  local OPENSSL_VERSION MAJOR
  OPENSSL_VERSION="$(openssl version 2>/dev/null | awk '{print $2}')"
  MAJOR="${OPENSSL_VERSION%%.*}"
  case "$MAJOR" in
    3) echo "3" ;;
    1) echo "1.1" ;;
    *) echo "unknown" ;;
  esac
}

validate_abi_expectation() {
  local ACTUAL_ABI="$1"
  if [ -z "$TARGET_OPENSSL_ABI" ]; then
    return 0
  fi
  if [ "$ACTUAL_ABI" = "unknown" ]; then
    echo "Unable to determine OpenSSL ABI (expected $TARGET_OPENSSL_ABI)." >&2
    return 1
  fi
  if [ "$ACTUAL_ABI" != "$TARGET_OPENSSL_ABI" ]; then
    echo "OpenSSL ABI mismatch: expected $TARGET_OPENSSL_ABI but build environment provides $ACTUAL_ABI." >&2
    return 1
  fi
}

build_local() {
  cd "$ROOT_DIR"
  validate_abi_expectation "$(detect_openssl_abi)"
  rm -rf "$ROOT_DIR/_build/prod"
  COWBOY_QUICER="$COWBOY_QUICER" COWBOY_QUIC="$COWBOY_QUIC" rebar3 as prod release
  validate_qpack_chrome_compat
}

# Return the shell commands needed to install Erlang/OTP + build deps inside
# the chosen base image before running rebar3.
setup_cmds() {
  cat <<'EOF'
if command -v dnf >/dev/null 2>&1; then
  dnf install -y epel-release
  dnf install -y git cmake make gcc gcc-c++ openssl-devel ncurses-devel
  if ! command -v erl >/dev/null 2>&1; then
    dnf install -y erlang
  fi
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y bash git build-essential cmake ninja-build perl libssl-dev libncurses-dev
  if ! command -v erl >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y erlang
  fi
else
  echo "Unsupported base image: neither dnf nor apt-get found" >&2
  exit 1
fi

if ! command -v rebar3 >/dev/null 2>&1; then
  curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3
  chmod +x /usr/local/bin/rebar3
fi
EOF
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
    -e TARGET_OPENSSL_ABI="$TARGET_OPENSSL_ABI" \
    "$ERLANG_DOCKER_IMAGE" \
    bash -lc "
      set -euo pipefail
      $(setup_cmds)
      if [ -n \"\${TARGET_OPENSSL_ABI}\" ]; then
        OPENSSL_VERSION=\$(openssl version | awk '{print \$2}')
        OPENSSL_MAJOR=\${OPENSSL_VERSION%%.*}
        if [ \"\$OPENSSL_MAJOR\" = \"3\" ]; then
          ACTUAL_ABI=3
        elif [ \"\$OPENSSL_MAJOR\" = \"1\" ]; then
          ACTUAL_ABI=1.1
        else
          ACTUAL_ABI=unknown
        fi
        if [ \"\$ACTUAL_ABI\" != \"\$TARGET_OPENSSL_ABI\" ]; then
          echo \"OpenSSL ABI mismatch in build image: expected \$TARGET_OPENSSL_ABI but got \$ACTUAL_ABI\" >&2
          exit 1
        fi
      fi
      rm -rf _build
      rebar3 as prod release

      REL_DIR=/src/_build/prod/rel/pertisk_eproxy
      ERL_BIN=\$(echo \"\$REL_DIR\"/erts-*/bin/erl)
      if [ ! -x \"\$ERL_BIN\" ]; then
        echo \"Release validation failed: erl not found in \$REL_DIR/erts-*/bin/erl\" >&2
        exit 1
      fi
      \"\$ERL_BIN\" -pa \"\$REL_DIR\"/lib/*/ebin -noshell -eval '
        case quic_qpack:encode([{<<":status">>, <<"200">>}]) of
          <<0,0,_/binary>> ->
            io:format("qpack_check=ok~n"),
            init:stop(0);
          Encoded ->
            io:format("qpack_check=bad encoded=~p~n", [Encoded]),
            init:stop(42)
        end.
      '
    "
}

case "$(uname -s)" in
  Linux)
    if [ "$FORCE_DOCKER_RELEASE" = "1" ]; then
      build_docker
    else
      build_local
    fi
    ;;
  *)
    build_docker
    ;;
esac