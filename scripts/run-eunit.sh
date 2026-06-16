#!/usr/bin/env bash
# Run eunit in parallel (one BEAM VM per module/batch). Each job uses a
# fresh BEAM VM. pertisk_eproxy_admin_handler_tests is split into batches because
# a single invocation exceeds the ~120s rebar3/eunit runner wall clock (~262 tests).
#
# Jobs call scripts/eunit-job.escript against precompiled beams. Parallel
# rebar3 eunit races on _build/test/*.beam (missing_module, failed renames).
#
# With --cover, each job instruments beams via cover:compile_beam_directory and
# writes coverdata under _build/test/cover/work/<job>/.
#
# Env:
#   EUNIT_PARALLEL                 max concurrent jobs (default: 4 with --cover, else min(8, CPU))
#   ADMIN_HANDLER_EUNIT_BATCH_SIZE tests per admin_handler batch (default: 80)
#   PERTISK_EUNIT_COVER_LOCAL_ONLY when --cover (default: 1 for single-node runs)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REBAR="${REBAR:-rebar3}"
COVER=0
ADMIN_BATCH_SIZE="${ADMIN_HANDLER_EUNIT_BATCH_SIZE:-80}"
CHUNK_DIR="${ROOT_DIR}/_build/test/cover/chunks"
COVER_WORK="${CHUNK_DIR}/work"
LOG_DIR="${ROOT_DIR}/_build/test/logs"
SEEN_DIR="${LOG_DIR}/seen"
SLOT_DIR="${LOG_DIR}/slots"
COVER_LOCK="${CHUNK_DIR}/.archive.lock.dir"
ADMIN_MOD="pertisk_eproxy_admin_handler_tests"
JOB_TOTAL=0
JOBS_STARTED=0

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
  local n cover_cap
  n="$(cpu_count)"
  if [ "$n" -gt 8 ]; then
    n=8
  fi
  if [ "$n" -lt 1 ]; then
    n=1
  fi
  if [ "$COVER" -eq 1 ]; then
    cover_cap=4
    if [ "$n" -gt "$cover_cap" ]; then
      n="$cover_cap"
    fi
  fi
  printf '%s' "$n"
}

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
  EUNIT_PARALLEL=${EUNIT_PARALLEL:-$(default_parallel)}
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

EUNIT_PARALLEL="${EUNIT_PARALLEL:-$(default_parallel)}"
case "$EUNIT_PARALLEL" in
  *[!0-9]*|'')
    echo "EUNIT_PARALLEL must be a positive integer (got: ${EUNIT_PARALLEL})" >&2
    exit 1
    ;;
  0)
    echo "EUNIT_PARALLEL must be >= 1 (got: 0)" >&2
    exit 1
    ;;
esac

cd "$ROOT_DIR"

clean_root_coverdata() {
  find "$ROOT_DIR" -maxdepth 1 -name '*.coverdata' -delete 2>/dev/null || true
}

reset_log_dir() {
  mkdir -p "$LOG_DIR"

  # A previous interrupted run can leave stale writers touching slot dirs.
  # Avoid hard-failing on transient "Directory not empty" races.
  local tries=0
  while [ "$tries" -lt 6 ]; do
    rm -rf "$SEEN_DIR" "$SLOT_DIR" 2>/dev/null || true
    find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true
    find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true

    if [ ! -d "$SEEN_DIR" ] && [ ! -d "$SLOT_DIR" ]; then
      break
    fi

    tries=$((tries + 1))
    sleep 0.05
  done

  mkdir -p "$SEEN_DIR" "$SLOT_DIR"
}

init_cover_chunks() {
  rm -rf "$CHUNK_DIR"
  mkdir -p "$COVER_WORK"
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

job_cover_base() {
  printf '%s/work/%s/eunit' "$CHUNK_DIR" "$1"
}

archive_cover_chunk() {
  local label="$1"
  local cover_base chunk_file
  cover_base="$(job_cover_base "$label")"
  chunk_file="$CHUNK_DIR/${label}.coverdata"
  if [ -f "${cover_base}.coverdata" ]; then
    cp "${cover_base}.coverdata" "$chunk_file"
    rm -f "${cover_base}.coverdata"
  fi
}

eunit_cover_env() {
  local safe_id="$1"
  if [ "$COVER" -eq 1 ]; then
    export PERTISK_EUNIT_COVER=1
    export PERTISK_EUNIT_COVER_LOCAL_ONLY="${PERTISK_EUNIT_COVER_LOCAL_ONLY:-1}"
    local cover_base
    cover_base="$(job_cover_base "$safe_id")"
    mkdir -p "$(dirname "$cover_base")"
    export PERTISK_EUNIT_COVER_EXPORT="$cover_base"
  else
    unset PERTISK_EUNIT_COVER PERTISK_EUNIT_COVER_EXPORT 2>/dev/null || true
  fi
}

sanitize_job_id() {
  printf '%s' "$1" | tr '/:+ ' '____'
}

lookup_job_id() {
  local safe_id="$1"
  awk -F '\t' -v id="$safe_id" '$1 == id { print $2; exit }' "$LOG_DIR/jobs.tsv" 2>/dev/null
}

lookup_job_start() {
  local safe_id="$1"
  awk -F '\t' -v id="$safe_id" '$1 == id { print $3; exit }' "$LOG_DIR/jobs.tsv" 2>/dev/null
}

progress_line() {
  printf '%s\n' "$*" >&2
}

acquire_slot() {
  local n=0
  while true; do
    n=0
    while [ "$n" -lt "$EUNIT_PARALLEL" ]; do
      if mkdir "${SLOT_DIR}/${n}" 2>/dev/null; then
        printf '%s' "$n"
        return 0
      fi
      n=$((n + 1))
    done
    sleep 0.05
  done
}

release_slot() {
  local slot="$1"
  rmdir "${SLOT_DIR}/${slot}" 2>/dev/null || true
}

active_slot_count() {
  find "$SLOT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

# $1=job_id  $2=rebar eunit args (e.g. --module=foo or --test=mod:a+b)
run_job() {
  local job_id="$1"
  local rebar_args="$2"
  local safe_id log exit_file start end elapsed rc slot
  safe_id="$(sanitize_job_id "$job_id")"
  log="${LOG_DIR}/${safe_id}.log"
  exit_file="${LOG_DIR}/${safe_id}.exit"

  slot="$(acquire_slot)"
  JOBS_STARTED=$((JOBS_STARTED + 1))
  start=$(date +%s)
  printf '%s\t%s\t%s\n' "$safe_id" "$job_id" "$start" >>"$LOG_DIR/jobs.tsv"
  progress_line "==> [start ${JOBS_STARTED}/${JOB_TOTAL}] ${job_id}"

  {
    trap 'release_slot "$slot"' EXIT
    echo "==> job ${job_id}"
    echo "==> scripts/eunit-job.escript ${rebar_args}"
    echo "==> started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export PERTISK_EUNIT_PARALLEL="${EUNIT_PARALLEL}"
    export ROOT_DIR="$ROOT_DIR"
    cd "$ROOT_DIR"
    eunit_cover_env "$safe_id"
    "${ROOT_DIR}/scripts/eunit-job.escript" ${rebar_args}
    rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    if [ "$COVER" -eq 1 ]; then
      with_cover_lock archive_cover_chunk "$safe_id"
    fi
    echo "==> finished exit=${rc} duration=${elapsed}s"
    printf '%s\n' "$rc" >"$exit_file"
    exit "$rc"
  } >"$log" 2>&1 &
}

enqueue_module_job() {
  local mod="$1"
  run_job "$mod" "--module=${mod}"
}

enqueue_admin_batch_job() {
  local batch_no="$1"
  local batch_tests="$2"
  local count="$3"
  local job_id="${ADMIN_MOD}#batch${batch_no}(${count})"
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
  if grep -qE 'missing_module|failed to rename.*\.beam|cant_open_file.*\.coverdata|coverdata.*enoent' "$log" 2>/dev/null; then
    echo "    --- build/cover race ---"
    grep -E 'missing_module|failed to rename.*\.beam|cant_open_file.*\.coverdata|coverdata.*enoent' "$log" | head -8 | sed 's/^/      /'
  fi
  if grep -qE 'cancelled|global_sqlite_lock_timeout|did not run|\{timeout,' "$log" 2>/dev/null; then
    echo "    --- cancelled / timeout ---"
    grep -E 'cancelled|timeout|global_sqlite|did not run|Pending|\{timeout,' "$log" | head -15 | sed 's/^/      /'
  fi
  if grep -qE '^\*\*\* ' "$log" 2>/dev/null; then
    echo "    --- eunit failures ---"
    grep -E '^\*\*\* ' "$log" | head -20 | sed 's/^/      /'
  fi
  if grep -qE '[0-9]+ tests, [1-9][0-9]* failures' "$log" 2>/dev/null; then
    echo "    --- summary ---"
    grep -E '[0-9]+ tests,' "$log" | tail -3 | sed 's/^/      /'
  fi
  if ! grep -qE '^\*\*\* | [1-9][0-9]* failures|cancelled' "$log" 2>/dev/null; then
    echo "    --- tail ---"
    tail -20 "$log" | sed 's/^/      /'
  fi
}

report_failures() {
  local failed=0 total=0 job safe_id log rc
  for exit_file in "$LOG_DIR"/*.exit; do
    [ -e "$exit_file" ] || continue
    total=$((total + 1))
    rc="$(tr -d '[:space:]' <"$exit_file")"
    [ "$rc" = "0" ] && continue
    failed=$((failed + 1))
  done
  if [ "$failed" -eq 0 ]; then
    return 0
  fi
  echo "" >&2
  echo "==> EUNIT FAILED: ${failed} of ${total} job(s)" >&2
  for exit_file in "$LOG_DIR"/*.exit; do
    [ -e "$exit_file" ] || continue
    rc="$(tr -d '[:space:]' <"$exit_file")"
    [ "$rc" = "0" ] && continue
    safe_id="$(basename "$exit_file" .exit)"
    log="${LOG_DIR}/${safe_id}.log"
    job="$(lookup_job_id "$safe_id")"
    [ -z "$job" ] && job="$safe_id"
    echo "" >&2
    echo "  [FAIL] ${job} (exit ${rc})" >&2
    print_failure_excerpt "$log" >&2
  done
  echo "" >&2
  echo "==> full logs: ${LOG_DIR}/" >&2
  return 1
}

wait_for_jobs_with_progress() {
  local completed=0 last_completed=0 stall_ticks=0 running job_id safe_id rc start_ts now elapsed
  while [ "$completed" -lt "$JOB_TOTAL" ]; do
    for exit_file in "$LOG_DIR"/*.exit; do
      [ -e "$exit_file" ] || continue
      safe_id="$(basename "$exit_file" .exit)"
      [ -f "${SEEN_DIR}/${safe_id}" ] && continue
      touch "${SEEN_DIR}/${safe_id}"
      rc="$(tr -d '[:space:]' <"$exit_file")"
      job_id="$(lookup_job_id "$safe_id")"
      [ -z "$job_id" ] && job_id="$safe_id"
      start_ts="$(lookup_job_start "$safe_id")"
      now=$(date +%s)
      if [ -n "$start_ts" ]; then
        elapsed=$((now - start_ts))
      else
        elapsed=0
      fi
      completed=$((completed + 1))
      if [ "$rc" = "0" ]; then
        progress_line "==> [done ${completed}/${JOB_TOTAL}] OK   ${job_id} (${elapsed}s)"
      else
        progress_line "==> [done ${completed}/${JOB_TOTAL}] FAIL ${job_id} (${elapsed}s) — ${LOG_DIR}/${safe_id}.log"
      fi
    done

    if [ "$completed" -lt "$JOB_TOTAL" ]; then
      if [ "$completed" -eq "$last_completed" ]; then
        stall_ticks=$((stall_ticks + 1))
        if [ "$stall_ticks" -ge 20 ]; then
          running="$(active_slot_count)"
          progress_line "==> progress: ${completed}/${JOB_TOTAL} done, ${running} active (tail logs: ${LOG_DIR}/)"
          stall_ticks=0
        fi
      else
        last_completed=$completed
        stall_ticks=0
      fi
      sleep 0.5
    fi
  done
  builtin wait 2>/dev/null || true
}

if [ "$COVER" -eq 1 ]; then
  init_cover_chunks
fi

reset_log_dir
: >"$LOG_DIR/jobs.tsv"

echo "==> ensure test TLS fixtures (priv/tls/ is gitignored)"
bash "${ROOT_DIR}/scripts/ensure-test-tls.sh"

echo "==> ensure test admin UI stubs (priv/admin/ is gitignored)"
bash "${ROOT_DIR}/scripts/ensure-test-admin.sh"

echo "==> compile test profile (once before parallel eunit)"
$REBAR as test compile

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
JOB_TOTAL=$(( ${#MODULES[@]} + admin_batches ))

cover_note=""
if [ "$COVER" -eq 1 ]; then
  cover_note=" (cover capped at 4 workers; set EUNIT_PARALLEL to override)"
fi
echo "==> eunit parallel: ${EUNIT_PARALLEL} workers, ${JOB_TOTAL} job(s) (${#MODULES[@]} modules + ${admin_batches} admin batch(es))${cover_note}"
echo "==> per-job logs: ${LOG_DIR}/"

set +e
for mod in "${MODULES[@]}"; do
  enqueue_module_job "$mod" &
done
collect_admin_batches &
wait
wait_for_jobs_with_progress
set -e

if report_failures; then
  echo "==> eunit passed (${JOB_TOTAL} job(s))"
else
  exit 1
fi

if [ "$COVER" -eq 1 ]; then
  chunk_count="$(find "$CHUNK_DIR" -maxdepth 1 -name '*.coverdata' | wc -l | tr -d ' ')"
  echo "==> cover: archived ${chunk_count} chunk(s) in ${CHUNK_DIR}"
  echo "==> cover: run scripts/merge-cover.escript to build eunit.coverdata"
  clean_root_coverdata
  rm -rf "$COVER_WORK"
fi
