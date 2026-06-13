#!/usr/bin/env bash
# Run eunit in batches. pertisk_eproxy_admin_handler_tests exceeds the ~120s
# rebar3/eunit runner wall clock for a single invocation (~262 tests).
#
# With --cover, each module run is archived separately. Rebar3's incremental
# eunit.coverdata merge zeroes modules that were covered in earlier runs; we
# merge chunks with scripts/merge-cover.escript (best coverage per module).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REBAR="${REBAR:-rebar3}"
COVER=0
ADMIN_BATCH_SIZE="${ADMIN_HANDLER_EUNIT_BATCH_SIZE:-120}"
CHUNK_DIR="${ROOT_DIR}/_build/test/cover/chunks"
COVER_OUT="${ROOT_DIR}/_build/test/cover/eunit.coverdata"
CHUNK_SEQ=0

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

clean_root_coverdata() {
  find "$ROOT_DIR" -maxdepth 1 -name '*.coverdata' -delete 2>/dev/null || true
}

init_cover_chunks() {
  rm -rf "$CHUNK_DIR"
  mkdir -p "$CHUNK_DIR"
  rm -f "$COVER_OUT"
  clean_root_coverdata
}

archive_cover_chunk() {
  local label="$1"
  local chunk_file="$CHUNK_DIR/${label}.coverdata"
  if [ -f "$COVER_OUT" ]; then
    cp "$COVER_OUT" "$chunk_file"
    rm -f "$COVER_OUT"
  fi
  clean_root_coverdata
}

finalize_cover() {
  if [ ! -d "$CHUNK_DIR" ] || [ -z "$(find "$CHUNK_DIR" -maxdepth 1 -name '*.coverdata' -print -quit)" ]; then
    echo "==> cover: no chunk files to merge" >&2
    return 1
  fi
  echo "==> cover: merging chunks (best coverage per module)"
  ROOT_DIR="$ROOT_DIR" "$ROOT_DIR/scripts/merge-cover.escript" "$CHUNK_DIR" "$COVER_OUT" merge
}

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
  if [ "$COVER" -eq 1 ]; then
    CHUNK_SEQ=$((CHUNK_SEQ + 1))
    archive_cover_chunk "$(printf '%04d_%s' "$CHUNK_SEQ" "$mod")"
  fi
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
    if [ "$COVER" -eq 1 ]; then
      CHUNK_SEQ=$((CHUNK_SEQ + 1))
      archive_cover_chunk "$(printf '%04d_%s_batch%d' "$CHUNK_SEQ" "$mod" "$batch_no")"
    fi
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

if [ "$COVER" -eq 1 ]; then
  init_cover_chunks
fi

ADMIN_MOD="pertisk_eproxy_admin_handler_tests"

while IFS= read -r mod; do
  [ "$mod" = "$ADMIN_MOD" ] && continue
  run_module "$mod"
done < <(find "$ROOT_DIR/test" -maxdepth 1 -name '*_tests.erl' -print \
  | sed 's|.*/||;s|\.erl||' \
  | sort \
  | grep -v "^${ADMIN_MOD}$")

# Largest module; batch to stay under the ~120s eunit runner limit. Run last so
# earlier modules are not affected by accumulated SQLite/config state.
run_admin_handler_batches

if [ "$COVER" -eq 1 ]; then
  echo "==> cover: archived $(find "$CHUNK_DIR" -maxdepth 1 -name '*.coverdata' | wc -l | tr -d ' ') chunk(s) in $CHUNK_DIR"
  echo "==> cover: run scripts/merge-cover.escript to build eunit.coverdata"
fi
