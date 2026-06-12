#!/usr/bin/env bash
# Run eunit in batches. pertisk_eproxy_admin_handler_tests exceeds the ~120s
# rebar3/eunit runner wall clock for a single invocation (~262 tests).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REBAR="${REBAR:-rebar3}"
COVER=0
ADMIN_BATCH_SIZE="${ADMIN_HANDLER_EUNIT_BATCH_SIZE:-120}"

while [ $# -gt 0 ]; do
  case "$1" in
    --cover) COVER=1; shift ;;
    -h|--help)
      echo "usage: $0 [--cover]" >&2
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"

eunit_cover_arg() {
  if [ "$COVER" -eq 1 ]; then
    printf '%s' "--cover"
  fi
}

run_module() {
  local mod="$1"
  echo "==> eunit ${mod}"
  # shellcheck disable=SC2046
  $REBAR eunit $(eunit_cover_arg) --module="$mod"
}

run_admin_handler_batches() {
  local mod="pertisk_eproxy_admin_handler_tests"
  local test_file="$ROOT_DIR/test/${mod}.erl"
  local batch="" batch_no=0 count=0

  flush_batch() {
    [ -z "$batch" ] && return 0
    batch_no=$((batch_no + 1))
    echo "==> eunit ${mod} (batch ${batch_no}, ${count} tests)"
    # shellcheck disable=SC2046
    $REBAR eunit $(eunit_cover_arg) --test="${mod}:${batch}"
    batch=""
    count=0
  }

  while IFS= read -r line; do
    t="${line%%()}"
    if [ -z "$batch" ]; then
      batch="$t"
    else
      batch="${batch}+${t}"
    fi
    count=$((count + 1))
    if [ "$count" -ge "$ADMIN_BATCH_SIZE" ]; then
      flush_batch
    fi
  done < <(grep -E '^[a-z_][a-z0-9_]*_test\(\)' "$test_file" | sed 's/().*//')

  flush_batch
}

while IFS= read -r mod; do
  if [ "$mod" = "pertisk_eproxy_admin_handler_tests" ]; then
    run_admin_handler_batches
  else
    run_module "$mod"
  fi
done < <(find "$ROOT_DIR/test" -maxdepth 1 -name '*_tests.erl' -print \
  | sed 's|.*/||;s|\.erl||' \
  | sort)
