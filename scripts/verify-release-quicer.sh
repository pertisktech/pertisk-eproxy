#!/usr/bin/env bash
# Fail the release build if Cowboy was not built with start_quic/3 or quicer is missing.
set -euo pipefail

ROOT="${1:-.}"
REL_ROOT="${ROOT}/_build/prod/rel/pertisk_eproxy"
REL_LIB="${REL_ROOT}/lib"
if [ ! -d "$REL_LIB" ]; then
  REL_ROOT="${ROOT}/_build/default/rel/pertisk_eproxy"
  REL_LIB="${REL_ROOT}/lib"
fi

if [ ! -d "$REL_LIB" ]; then
  echo "verify-release-quicer: release lib missing (expected under _build/*/rel/pertisk_eproxy/lib)" >&2
  exit 1
fi

QUICER_DIR=$(find "$REL_LIB" -maxdepth 1 -type d -name 'quicer-*' 2>/dev/null | head -1)
if [ -z "$QUICER_DIR" ]; then
  echo "verify-release-quicer: quicer application not packaged in release" >&2
  exit 1
fi

COWBOY_EBIN=$(find "$REL_LIB" -maxdepth 2 -type d -path '*/cowboy-*/ebin' 2>/dev/null | head -1)
QUICER_EBIN="${QUICER_DIR}/ebin"
if [ -z "$COWBOY_EBIN" ] || [ ! -d "$QUICER_EBIN" ]; then
  echo "verify-release-quicer: cowboy or quicer ebin missing" >&2
  exit 1
fi

# Prefer host erl (avoid release wrapper looking for start.boot).
if command -v erl >/dev/null 2>&1; then
  run_erl() { erl -noshell -noinput "$@"; }
else
  ERTS_BIN=$(ls "${REL_ROOT}"/erts-*/bin/erl 2>/dev/null | head -1 || true)
  if [ -z "$ERTS_BIN" ]; then
    ERTS_BIN=$(find "${ROOT}/_build" -path '*/erts-*/bin/erl' 2>/dev/null | head -1)
  fi
  if [ -z "$ERTS_BIN" ]; then
    echo "verify-release-quicer: erl not found" >&2
    exit 1
  fi
  run_erl() { "$ERTS_BIN" -boot start_clean -noshell -noinput "$@"; }
fi

if [ -d "${QUICER_DIR}/priv" ]; then
  export LD_LIBRARY_PATH="${QUICER_DIR}/priv${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

run_erl -pa "$COWBOY_EBIN" -pa "$QUICER_EBIN" -eval '
  case code:ensure_loaded(cowboy) of
    {module, cowboy} ->
      case erlang:function_exported(cowboy, start_quic, 3) of
        true ->
          io:format("verify-release-quicer: cowboy:start_quic/3 ok~n"),
          halt(0);
        false ->
          io:format(standard_error,
            "verify-release-quicer: cowboy loaded but start_quic/3 missing "
            "(need -define(COWBOY_QUICER) / patch-cowboy-quic.sh)~n exports=~p~n",
            [cowboy:module_info(exports)]),
          halt(1)
      end;
    Other ->
      io:format(standard_error, "verify-release-quicer: ensure_loaded(cowboy) -> ~p~n", [Other]),
      halt(1)
  end.
'

if [ -d "${QUICER_DIR}/priv" ]; then
  if ! find "${QUICER_DIR}/priv" -type f \( -name '*.so' -o -name 'libmsquic*' \) 2>/dev/null | grep -q .; then
    echo "verify-release-quicer: warning: no .so/libmsquic under ${QUICER_DIR}/priv" >&2
  else
    echo "verify-release-quicer: native libs present under ${QUICER_DIR}/priv"
  fi
fi

echo "verify-release-quicer: all checks passed"
