#!/usr/bin/env bash
# Shared Erlang toolchain check for self-hosted CI runners.
set -euo pipefail

REBAR3_VERSION="${REBAR3_VERSION:-3.24.0}"

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
  local install_dir="${REBAR3_INSTALL_DIR:-${HOME}/.local/bin}"
  local dest="${install_dir}/rebar3"
  command -v curl >/dev/null 2>&1 || {
    echo "rebar3 not found and curl is unavailable to bootstrap it" >&2
    return 1
  }
  mkdir -p "$install_dir"
  echo "Bootstrapping rebar3 ${REBAR3_VERSION} -> ${dest}" >&2
  curl -fsSL "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" -o "$dest"
  chmod +x "$dest"
  persist_path_dir "$install_dir"
}

if ! command -v erl >/dev/null 2>&1; then
  echo "erl not found in PATH: ${PATH}" >&2
  exit 1
fi

if ! find_rebar3; then
  bootstrap_rebar3 || true
fi

if ! command -v rebar3 >/dev/null 2>&1; then
  echo "rebar3 not found in PATH: ${PATH}" >&2
  echo "Install rebar3 on the runner or allow curl to bootstrap ${REBAR3_VERSION}." >&2
  exit 1
fi

otp="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')"
echo "OTP ${otp}, $(erl -noshell -eval 'io:format("~s", [erlang:system_info(system_version)]), halt().')"
rebar3 version

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
