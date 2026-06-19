#!/usr/bin/env bash
# Shared Erlang toolchain check for self-hosted CI runners.
set -euo pipefail

if ! command -v erl >/dev/null 2>&1; then
  echo "erl not found in PATH: ${PATH}" >&2
  exit 1
fi

if ! command -v rebar3 >/dev/null 2>&1; then
  for candidate in \
    "${HOME}/.local/bin/rebar3" \
    /usr/local/bin/rebar3 \
    /usr/bin/rebar3; do
    if [ -x "$candidate" ]; then
      export PATH="$(dirname "$candidate"):${PATH}"
      break
    fi
  done
fi

if ! command -v rebar3 >/dev/null 2>&1; then
  echo "rebar3 not found in PATH: ${PATH}" >&2
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
