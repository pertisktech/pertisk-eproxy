#!/usr/bin/env bash
# Shared Erlang toolchain check for self-hosted CI runners.
set -euo pipefail

# 3.27.0+ required for OTP 29 (3.24.x escript beams fail to load).
REBAR3_VERSION="${REBAR3_VERSION:-3.27.1}"

persist_path_dir() {
  local dir="$1"
  case ":${PATH}:" in
    *":${dir}:"*) ;;
    *) export PATH="${dir}:${PATH}" ;;
  esac
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$dir" >> "$GITHUB_PATH"
  fi
}

find_rebar3() {
  local candidate
  for candidate in \
    "${REBAR3:-}" \
    "${REBAR3_BIN:-}" \
    "$(command -v rebar3 2>/dev/null || true)" \
    "${HOME}/.local/bin/rebar3" \
    "${HOME}/.cargo/bin/rebar3" \
    /usr/local/bin/rebar3 \
    /usr/bin/rebar3 \
    /opt/rebar3/bin/rebar3; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    persist_path_dir "$(dirname "$candidate")"
    return 0
  done
  return 1
}

bootstrap_rebar3() {
  local version="${1:-$REBAR3_VERSION}"
  local install_dir="${REBAR3_INSTALL_DIR:-${HOME}/.local/bin}"
  local dest="${install_dir}/rebar3"
  command -v curl >/dev/null 2>&1 || {
    echo "rebar3 not found and curl is unavailable to bootstrap it" >&2
    return 1
  }
  mkdir -p "$install_dir"
  echo "Bootstrapping rebar3 ${version} -> ${dest}" >&2
  curl -fsSL "https://github.com/erlang/rebar3/releases/download/${version}/rebar3" -o "$dest"
  chmod +x "$dest"
  # Drop extracted vendor beams from older rebar3/OTP combos.
  rm -rf "${HOME}/.cache/rebar3" 2>/dev/null || true
  persist_path_dir "$install_dir"
}

rebar3_works() {
  command -v rebar3 >/dev/null 2>&1 || return 1
  rebar3 version >/dev/null 2>&1
}

if ! command -v erl >/dev/null 2>&1; then
  echo "erl not found in PATH: ${PATH}" >&2
  exit 1
fi

otp="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')"
echo "OTP ${otp}, $(erl -noshell -eval 'io:format("~s", [erlang:system_info(system_version)]), halt().')"

case "${otp}" in
  ''|*[!0-9]*)
    echo "Unexpected OTP release value: '${otp}'" >&2
    exit 1
    ;;
esac

if [ "${otp}" -lt 26 ] || [ "${otp}" -gt 30 ]; then
  echo "Expected OTP 26–30 on the self-hosted runner (got ${otp})." >&2
  exit 1
fi

# OTP 29+ needs rebar3 3.27+; keep an overrideable pin via REBAR3_VERSION.
if [ "${otp}" -ge 29 ]; then
  case "${REBAR3_VERSION}" in
    3.2[0-6].*|3.1*|3.0*|2.*)
      echo "REBAR3_VERSION=${REBAR3_VERSION} is too old for OTP ${otp}; using 3.27.1" >&2
      REBAR3_VERSION="3.27.1"
      ;;
  esac
fi

if ! find_rebar3; then
  bootstrap_rebar3 "$REBAR3_VERSION" || true
fi

if ! rebar3_works; then
  echo "Existing rebar3 is missing or incompatible with OTP ${otp}; re-bootstrapping ${REBAR3_VERSION}" >&2
  bootstrap_rebar3 "$REBAR3_VERSION" || true
fi

if ! command -v rebar3 >/dev/null 2>&1; then
  echo "rebar3 not found in PATH: ${PATH}" >&2
  echo "Install rebar3 on the runner or allow curl to bootstrap ${REBAR3_VERSION}." >&2
  exit 1
fi

if ! rebar3_works; then
  echo "rebar3 failed to run under OTP ${otp}." >&2
  echo "Install rebar3 >= 3.27.0 (for OTP 29) or set REBAR3_VERSION accordingly." >&2
  rebar3 version || true
  exit 1
fi

rebar3 version

# quicer/msquic NIF needs libatomic (+ numa headers) on Linux runners.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(uname -s)" = "Linux" ]; then
  bash "${SCRIPT_DIR}/ci-ensure-quicer-build-deps.sh"
fi
