#!/usr/bin/env bash
# Apply pertisk HTTP/3 deferred invoke_handler patch to erlang_quic, then recompile if needed.
set -euo pipefail
ROOT="${REBAR_ROOT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
FILE="$ROOT/_build/default/lib/quic/src/h3/quic_h3_connection.erl"
if [[ ! -f "$FILE" ]]; then
  exit 0
fi
if grep -q 'pertisk-deferred-h3-invoke' "$FILE" 2>/dev/null; then
  exit 0
fi
python3 "$ROOT/scripts/patch_quic_h3_invoke_handler.py" "$FILE"
# Nested `rebar3 compile` may skip deps; drop the beam so quic_h3_connection is rebuilt.
rm -f "$ROOT/_build/default/lib/quic/ebin/quic_h3_connection.beam"
cd "$ROOT"
rebar3 compile
