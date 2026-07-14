#!/bin/sh
# Ensure Cowboy compiles start_quic/3 (MsQuic / quicer path) and honors num_acceptors.
set -e
ROOT="${REBAR_ROOT_DIR:-.}"
found=0

for f in $(find "${ROOT}/_build" "${ROOT}/deps" -path '*/cowboy/src/cowboy.erl' 2>/dev/null | sort -u); do
  found=1

  if ! grep -q '%% pertisk COWBOY_QUICER' "$f"; then
    if ! grep -q '^-define(COWBOY_QUICER' "$f"; then
      perl -i -pe 'if (!$done && /^-module\(cowboy\)\./) { $_ .= "-define(COWBOY_QUICER, true). %% pertisk COWBOY_QUICER\n"; $done=1 }' "$f"
      echo "patch-cowboy-quic: defined COWBOY_QUICER in $f"
    fi
  fi

  # Cowboy master hardcodes 20 acceptors; honour TransOpts num_acceptors (Ranch-style).
  if ! grep -q '%% pertisk QUIC acceptors' "$f"; then
    if grep -q 'lists:seq(1, 20)' "$f"; then
      perl -i -0pe 's/_AcceptorPid = \[spawn\(fun AcceptLoop\(\) ->(.*?)end\) \|\| _ <- lists:seq\(1, 20\)\],/_NAcc = maps:get(num_acceptors, TransOpts, 20),\n\t_AcceptorPid = [spawn(fun AcceptLoop() ->$1end) || _ <- lists:seq(1, max(1, min(256, _NAcc)))], %% pertisk QUIC acceptors/s' "$f"
      echo "patch-cowboy-quic: num_acceptors wired in $f"
    fi
  fi

  rm -f "$(dirname "$f")/../ebin/cowboy.beam" 2>/dev/null || true
done

if [ "$found" -eq 0 ]; then
  echo "patch-cowboy-quic: no cowboy.erl under _build/deps (run rebar3 get-deps first)" >&2
  exit 1
fi

echo "patch-cowboy-quic: ok"
