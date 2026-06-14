#!/usr/bin/env bash
# Run eunit in parallel (one rebar3 invocation per module/batch). Each job uses a
# fresh BEAM VM. pertisk_eproxy_admin_handler_tests is split into batches because
# a single invocation exceeds the ~120s rebar3/eunit runner wall clock (~262 tests).
#
# With --cover, each job archives coverdata separately. Rebar3's incremental
# eunit.coverdata merge zeroes modules covered in earlier runs; merge chunks with
# scripts/merge-cover.escript (best coverage per module).
#
# Env:
#   EUNIT_PARALLEL                 max concurrent jobs (default: min(8, CPU count))
#   ADMIN_HANDLER_EUNIT_BATCH_SIZE tests per admin_handler batch (default: 120)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REBAR="${REBAR:-rebar3}"
COVER=0
ADMIN_BATCH_SIZE="${ADMIN_HANDLER_EUNIT_BATCH_SIZE:-120}"
CHUNK_DIR="${ROOT_DIR}/_build/test/cover/chunks"
COVER_OUT="${ROOT_DIR}/_build/test/cover/eunit.coverdata"
LOG_DIR="${ROOT_DIR}/_build/test/logs"
FAILURES_FILE="${LOG_DIR}/.failures"
COVER_LOCK="${CHUNK_DIR}/.archive.lock.dir"
ADMIN_MOD="pertisk_eproxy_admin_handler_tests"

cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif [ "$(uname -s)" = "Darwin" ]; then
    sysctl -n hw.ncpu 2>/dev/null || echo 4
  else
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
  fi
}

default_parallel() {
  local n
  n="$(cpu_count)"
  if [ "$n" -gt 8 ]; then
    n=8
  fi
  if [ "$n" -lt 1 ]; then
    n=1
  fi
  printf '%s' "$n"
}

EUNIT_PARALLEL="${EUNIT_PARALLEL:-$(default_parallel)}"
if ! [[ "$EUNIT_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "EUNIT_PARALLEL must be a positive integer (got: ${EUNIT_PARALLEL})" >&2
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --cover) COVER=1; shift ;;
    -h|--help)
      cat <<EOF
usage: $0 [--cover]

Run all eunit modules in parallel (default $(default_parallel) jobs; override with EUNIT_PARALLEL).

Options:
  --cover   collect per-job coverdata chunks for merge-cover.escript

Env:
  EUNIT_PARALLEL=${EUNIT_PARALLEL}
  ADMIN_HANDLER_EUNIT_BATCH_SIZE=${ADMIN_BATCH_SIZE}
EOF
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

with_cover_lock() {
  while ! mkdir "$COVER_LOCK" 2>/dev/null; do
    sleep 0.02
  done
  "$@"
  local rc=$?
  rmdir "$COVER_LOCK" 2>/dev/null || true
  return "$rc"
}

archive_cover_chunk() {
  local label="$1"
  local chunk_file="$CHUNK_DIR/${label}.coverdata"
  if [ -f "$COVER_OUT" ]; then
    cp "$COVER_OUT" "$chunk_file"
    rm -f "$COVER_OUT"
  fi
}

eunit_cover_arg() {
  if [ "$COVER" -eq 1 ]; then
    export PERTISK_EUNIT_COVER=1
    printf '%s' "--cover"
  fi
}

sanitize_job_id() {
  printf '%s' "$1" | tr '/:+ ' '____'
}

# $1=job_id  $2=rebar eunit args (e.g. --module=foo or --test=mod:a+b)
run_job() {
  local job_id="$1"
  local rebar_args="$2"
  local safe_id log exit_file start end elapsed rc
  safe_id="$(sanitize_job_id "$job_id")"
  log="${LOG_DIR}/${safe_id}.log"
  exit_file="${LOG_DIR}/${safe_id}.exit"

  {
    echo "==> job ${job_id}"
    echo "==> rebar3 eunit ${rebar_args}"
    echo "==> started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    start=$(date +%s)
    # shellcheck disable=SC2046
    $REBAR eunit $(eunit_cover_arg) ${rebar_args}
    rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    if [ "$COVER" -eq 1 ]; then
      with_cover_lock archive_cover_chunk "$safe_id"
    fi
    echo "==> finished exit=${rc} duration=${elapsed}s"
    printf '%s\n' "$rc" >"$exit_file"
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$job_id" >>"$FAILURES_FILE"
    fi
    exit "$rc"
  } >"$log" 2>&1 &
}

wait_for_slot() {
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$EUNIT_PARALLEL" ]; do
    sleep 0.05
  done
}

enqueue_module_job() {
  local mod="$1"
  wait_for_slot
  run_job "$mod" "--module=${mod}"
}

enqueue_admin_batch_job() {
  local batch_no="$1"
  local batch_tests="$2"
  local count="$3"
  local job_id="${ADMIN_MOD}#batch${batch_no}(${count})"
  wait_for_slot
  run_job "$job_id" "--test=${ADMIN_MOD}:${batch_tests}"
}

collect_admin_batches() {
  local mod="$ADMIN_MOD"
  local test_file="$ROOT_DIR/test/${mod}.erl"
  local batch="" batch_no=0 count=0

  flush_batch() {
    [ -z "$batch" ] && return 0
    batch_no=$((batch_no + 1))
    enqueue_admin_batch_job "$batch_no" "$batch" "$count"
    batch=""
    count=0
  }

  while IFS= read -r line; do
    local t="${line%%()}"
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

print_failure_excerpt() {
  local log="$1"
  if [ ! -f "$log" ]; then
    echo "    (log missing: $log)"
    return 0
  fi
  echo "    log: $log"
  if grep -qE '^\*\*\* ' "$log" 2>/dev/null; then
    echo "    --- eunit failures ---"
    grep -E '^\*\*\* ' "$log" | head -20 | sed 's/^/      /'
  fi
  if grep -qE 'Failed: [1-9]' "$log" 2>/dev/null; then
    echo "    --- summary ---"
    grep -E 'Failed:|Skipped:|Passed:' "$log" | tail -3 | sed 's/^/      /'
  fi
  if ! grep -qE '^\*\*\* |Failed: [1-9]' "$log" 2>/dev/null; then
    echo "    --- tail ---"
    tail -25 "$log" | sed 's/^/      /'
  fi
}

report_failures() {
  local failed total job safe_id log
  if [ ! -f "$FAILURES_FILE" ]; then
    return 0
  fi
  failed="$(sort -u "$FAILURES_FILE" | sed '/^$/d' | wc -l | tr -d ' ')"
  total="$(find "$LOG_DIR" -maxdepth 1 -name '*.exit' | wc -l | tr -d ' ')"
  echo "" >&2
  echo "==> EUNIT FAILED: ${failed} of ${total} job(s)" >&2
  while IFS= read -r job; do
    [ -z "$job" ] && continue
    safe_id="$(sanitize_job_id "$job")"
    log="${LOG_DIR}/${safe_id}.log"
    echo "" >&2
    echo "  [FAIL] ${job}" >&2
    print_failure_excerpt "$log" >&2
  done < <(sort -u "$FAILURES_FILE")
  echo "" >&2
  echo "==> full logs: ${LOG_DIR}/" >&2
  return 1
}

if [ "$COVER" -eq 1 ]; then
  init_cover_chunks
fi

rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"
: >"$FAILURES_FILE"

echo "==> compile (once before parallel eunit)"
$REBAR compile

MODULES=()
while IFS= read -r mod; do
  MODULES+=("$mod")
done < <(
  find "$ROOT_DIR/test" -maxdepth 1 -name '*_tests.erl' -print \
    | sed 's|.*/||;s|\.erl||' \
    | sort \
    | grep -v "^${ADMIN_MOD}$"
)

admin_batches=0
if [ -f "$ROOT_DIR/test/${ADMIN_MOD}.erl" ]; then
  admin_batches=$(( ($(grep -cE '^[a-z_][a-z0-9_]*_test\(\)' "$ROOT_DIR/test/${ADMIN_MOD}.erl") + ADMIN_BATCH_SIZE - 1) / ADMIN_BATCH_SIZE ))
fi
job_total=$(( ${#MODULES[@]} + admin_batches ))

echo "==> eunit parallel: ${EUNIT_PARALLEL} workers, ${job_total} job(s) (${#MODULES[@]} modules + ${admin_batches} admin batch(es))"

set +e
for mod in "${MODULES[@]}"; do
  enqueue_module_job "$mod"
done
collect_admin_batches
wait
set -e

if report_failures; then
  echo "==> eunit passed (${job_total} job(s))"
else
  exit 1
fi

if [ "$COVER" -eq 1 ]; then
  chunk_count="$(find "$CHUNK_DIR" -maxdepth 1 -name '*.coverdata' | wc -l | tr -d ' ')"
  echo "==> cover: archived ${chunk_count} chunk(s) in ${CHUNK_DIR}"
  echo "==> cover: run scripts/merge-cover.escript to build eunit.coverdata"
  clean_root_coverdata
fi
