#!/usr/bin/env bash
# Linux prod release (local or Docker on macOS).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# HTTP/3 release builds with Cowboy QUIC hooks enabled.
COWBOY_QUICER="${COWBOY_QUICER:-1}"
COWBOY_QUIC="${COWBOY_QUIC:-1}"
ERLANG_BUILD_IMAGE="${ERLANG_BUILD_IMAGE:-erlang:29}"
RELEASE_BUILD_FORCE_DOCKER="${RELEASE_BUILD_FORCE_DOCKER:-0}"
RELEASE_BUILD_PLATFORM="${RELEASE_BUILD_PLATFORM:-}"
cache_volume_suffix() {
  local platform="${RELEASE_BUILD_PLATFORM:-}"
  platform="${platform#linux/}"
  if [ -n "$platform" ]; then
    printf '%s' "$platform"
  elif [ "$(uname -s)" = "Linux" ]; then
    uname -m
  else
    printf 'docker'
  fi
}

BUILD_CACHE_VOLUME="${BUILD_CACHE_VOLUME:-pertisk-eproxy-linux-build-$(cache_volume_suffix)}"
DEPS_CACHE_VOLUME="${DEPS_CACHE_VOLUME:-pertisk-eproxy-linux-deps-$(cache_volume_suffix)}"
# +JMsingle: QEMU/emulated amd64 builds (Apple Silicon); -noinput: no TTY in CI/Docker.
ERL_FLAGS="${ERL_FLAGS:-+JMsingle true -noshell -noinput}"
ERL_AFLAGS="${ERL_AFLAGS:--noshell -noinput}"

clean_build_tree() {
  # tmpfs mounts at _build/deps cannot be removed; only their contents.
  if [ -d _build ] && mountpoint -q _build 2>/dev/null; then
    find _build -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  elif [ -e _build ]; then
    rm -rf _build
  fi
  if [ -d deps ] && mountpoint -q deps 2>/dev/null; then
    find deps -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  elif [ -e deps ]; then
    rm -rf deps
  fi
}

prepare_and_release() {
  cd "$ROOT_DIR"
  # Never reuse host _build/ in Docker (macOS beams break relx xref on Linux). Same as docker/Dockerfile.proxy.
  clean_build_tree
  rebar3 get-deps
  bash scripts/patch-ekub.sh
  bash scripts/patch-quic.sh
  bash scripts/patch-hackney.sh
  bash scripts/verify-deps.sh "$ROOT_DIR"
  COWBOY_QUICER="$COWBOY_QUICER" COWBOY_QUIC="$COWBOY_QUIC" rebar3 as prod release
  bash scripts/verify-release-quic.sh "$ROOT_DIR"
}

# Tar the release onto the host bind mount. Snapshot on the Linux volume first so relx
# post-steps cannot mutate files mid-archive; host install unpacks the tarball.
stage_linux_release_export() {
  cd "$ROOT_DIR"
  local REL_SRC="_build/prod/rel/pertisk_eproxy"
  local REL_STAGE="_build/.release-export/pertisk_eproxy"
  local REL_TAR="_release_export/pertisk_eproxy.tgz"
  if [ ! -d "$REL_SRC" ]; then
    echo "stage_linux_release_export: release missing at $REL_SRC" >&2
    exit 1
  fi
  rm -rf "_build/.release-export" "_release_export"
  mkdir -p "_build/.release-export" "_release_export"
  cp -a "$REL_SRC" "$REL_STAGE"
  sync
  tar -C "_build/.release-export" -czf "$REL_TAR" pertisk_eproxy
  rm -rf "_build/.release-export"
  echo "stage_linux_release_export: ok ($REL_TAR)"
}

install_staged_release_on_host() {
  local REL_TAR="$ROOT_DIR/_release_export/pertisk_eproxy.tgz"
  local REL_DST="$ROOT_DIR/_build/prod/rel/pertisk_eproxy"
  if [ ! -f "$REL_TAR" ]; then
    echo "install_staged_release_on_host: staged tarball missing at $REL_TAR" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$REL_DST")"
  rm -rf "$REL_DST"
  tar -xzf "$REL_TAR" -C "$(dirname "$REL_DST")"
  rm -rf "$ROOT_DIR/_release_export"
  echo "install_staged_release_on_host: ok ($REL_DST)"
}

build_local() {
  export ERL_FLAGS="${ERL_FLAGS}"
  export ERL_AFLAGS="${ERL_AFLAGS}"
  prepare_and_release
}

maybe_reset_build_volumes() {
  if [ "${RELEASE_BUILD_CLEAN:-0}" = "1" ]; then
    echo "RELEASE_BUILD_CLEAN=1: removing Docker build volumes"
    docker volume rm -f "$BUILD_CACHE_VOLUME" "$DEPS_CACHE_VOLUME" >/dev/null 2>&1 || true
  fi
  docker volume create "$BUILD_CACHE_VOLUME" >/dev/null
  docker volume create "$DEPS_CACHE_VOLUME" >/dev/null
}

docker_build_release() {
  local PLATFORM_OPT=()
  if [ -n "$RELEASE_BUILD_PLATFORM" ]; then
    echo "Using Docker platform: $RELEASE_BUILD_PLATFORM"
    PLATFORM_OPT=(--platform "$RELEASE_BUILD_PLATFORM")
  fi

  maybe_reset_build_volumes

  # Linux-native Docker volumes for _build/deps (bind-mounting from macOS causes partial
  # compiles: unicode_util_compat ebin ENOENT, relx {missing_module,cow_http_hd}).
  # shellcheck disable=SC2086
  docker run --rm \
    ${PLATFORM_OPT[@]+"${PLATFORM_OPT[@]}"} \
    -v "$ROOT_DIR:/src" \
    -v "$BUILD_CACHE_VOLUME:/src/_build" \
    -v "$DEPS_CACHE_VOLUME:/src/deps" \
    -w /src \
    -e COWBOY_QUICER="$COWBOY_QUICER" \
    -e COWBOY_QUIC="$COWBOY_QUIC" \
    -e ERL_FLAGS="$ERL_FLAGS" \
    -e ERL_AFLAGS="$ERL_AFLAGS" \
    "$ERLANG_BUILD_IMAGE" \
    bash -lc '
      set -euo pipefail
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        bash git build-essential cmake ninja-build perl patch libssl-dev libncurses-dev util-linux
      export COWBOY_QUICER="'"$COWBOY_QUICER"'"
      export COWBOY_QUIC="'"$COWBOY_QUIC"'"
      export ERL_FLAGS="'"$ERL_FLAGS"'"
      export ERL_AFLAGS="'"$ERL_AFLAGS"'"
      bash scripts/build-release-linux.sh docker-inner
    '
}

build_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required to build a Linux release on $(uname -s)." >&2
    exit 1
  fi
  docker_build_release
  install_staged_release_on_host
}

if [ "${1:-}" = "docker-inner" ]; then
  prepare_and_release
  stage_linux_release_export
  exit 0
fi

host_matches_release_platform() {
  local want_cpu host_cpu
  [ -n "$RELEASE_BUILD_PLATFORM" ] || return 0
  want_cpu="${RELEASE_BUILD_PLATFORM#linux/}"
  host_cpu="$(uname -m)"
  case "$want_cpu" in
    amd64|x86_64)
      case "$host_cpu" in
        x86_64|amd64) return 0 ;;
      esac
      ;;
    arm64|aarch64)
      case "$host_cpu" in
        aarch64|arm64) return 0 ;;
      esac
      ;;
  esac
  return 1
}

if [ "$RELEASE_BUILD_FORCE_DOCKER" = "1" ]; then
  echo "RELEASE_BUILD_FORCE_DOCKER=1 set: building release in Docker"
  build_docker
  exit 0
fi

if [ -n "$RELEASE_BUILD_PLATFORM" ] && ! host_matches_release_platform; then
  echo "Cross-building release for $RELEASE_BUILD_PLATFORM on $(uname -m)/$(uname -s)"
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