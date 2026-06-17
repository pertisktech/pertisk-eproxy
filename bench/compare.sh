#!/usr/bin/env bash
#
# Workload matrix for pertisk-eproxy over HTTP/1.1 (wrk) and HTTP/2 (h2load).
#
# Each workload boots a fresh proxy + upstream stack on its own port so a heavy
# run cannot leave the listener in a bad state for the next row.
#
# Usage:
#   bench/compare.sh                       # full matrix, 4t/32c/10s
#   DUR=20 CONN=128 bench/compare.sh
#   SWEEP=1 bench/compare.sh               # concurrency sweep (H1 tiny)
#
# Requires: wrk, h2load, curl, rebar3, openssl.

set -euo pipefail
cd "$(dirname "$0")/.."

DUR="${DUR:-10}"
CONN="${CONN:-32}"
THREADS="${THREADS:-4}"
STREAMS="${STREAMS:-16}"
SWEEP="${SWEEP:-0}"

WORKLOADS=(
  "tiny:GET:/"
  "bytes1k:GET:/bytes/1024"
  "bytes10k:GET:/bytes/10240"
  "bytes100k:GET:/bytes/102400"
  "echo:POST:/echo"
)
ECHO_BODY='{"name":"ada","tags":["one","two","three"],"n":42,"ok":true}'
BENCH_HOST="${BENCH_HOST:-bench.local}"

for tool in wrk h2load curl rebar3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

echo "Compiling bench profile..."
COWBOY_QUICER="${COWBOY_QUICER:-1}" COWBOY_QUIC="${COWBOY_QUIC:-1}" \
  rebar3 as bench compile >/dev/null
BENCH_LIBS="$PWD/_build/bench/lib"
BENCH_PA="$BENCH_LIBS/pertisk_eproxy/bench"

TMP="$(mktemp -d)"
RESULTS="$TMP/results"
SERVE_LOG="$TMP/serve.log"
READY_FILE="$TMP/ready"
: >"$RESULTS"
: >"$SERVE_LOG"
printf '%s' "$ECHO_BODY" >"$TMP/body.json"
# wrk's Lua runtime does not see shell exports; embed the POST body directly.
lua_body=${ECHO_BODY//\\/\\\\}
lua_body=${lua_body//\'/\\\'}
cat >"$TMP/post.lua" <<LUA
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.headers["Host"] = "${BENCH_HOST}"
wrk.body = '${lua_body}'
LUA

cleanup() { stop_server; rm -rf "$TMP"; }
trap cleanup EXIT
SERVER_PID=""

serve_proto() { case "$1" in h1) echo h1 ;; h2) echo h2 ;; esac; }

h2_streams() { # conns max_streams
  local conns="$1" cap="${2:-$STREAMS}" m=$((conns / 4))
  [ "$m" -lt 2 ] && m=2
  [ "$m" -gt "$cap" ] && m=$cap
  echo "$m"
}

workload_tier() { # name
  case "$1" in
    tiny|bytes1k) echo light ;;
    *) echo heavy ;;
  esac
}

h2_bench_opts() { # workload conns
  local wl="$1" conns="$2" threads streams cap
  threads=2
  conns=$((conns / 2))
  [ "$conns" -lt 8 ] && conns=8
  cap=4
  if [ "$(workload_tier "$wl")" = heavy ]; then
    cap=2
    conns=$((conns / 2))
    [ "$conns" -lt 8 ] && conns=8
  fi
  streams=$(h2_streams "$conns" "$cap")
  echo "$threads $conns $streams"
}

h1_bench_conns() { # workload conns
  local wl="$1" conns="$2"
  if [ "$(workload_tier "$wl")" = heavy ]; then
    conns=$((conns / 2))
    [ "$conns" -lt 8 ] && conns=8
  fi
  echo "$conns"
}

stop_server() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    local waited=0
    while kill -0 "$SERVER_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  sleep 0.5
  rm -f "$READY_FILE"
  : >"$SERVE_LOG"
}

probe_ready() { # mode port
  case "$1" in
    h1) curl -fsS -H "Host: $BENCH_HOST" "http://127.0.0.1:$2/" >/dev/null 2>&1 ;;
    h2) curl -fsSk --http2 -H "Host: $BENCH_HOST" "https://127.0.0.1:$2/" >/dev/null 2>&1 ;;
  esac
}

wait_port_free() { # port
  local port="$1" i
  for i in $(seq 1 40); do
    if ! lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

start_server_wait() { # mode port
  local mode="$1" port="$2"
  stop_server
  if ! wait_port_free "$port"; then
    echo "warning: port $port still in use before $mode bench" >&2
  fi
  rm -f "$READY_FILE"
  PERTISK_BENCH_READY_FILE="$READY_FILE" ERL_CRASH_DUMP_SECONDS=0 ERL_LIBS="$BENCH_LIBS" \
    erl -noshell -pa "$BENCH_PA" \
    -eval "pertisk_eproxy_bench:serve($(serve_proto "$mode"), $port)" \
    >/dev/null 2>>"$SERVE_LOG" &
  SERVER_PID=$!
  local i ready=0
  for i in $(seq 1 60); do
    if grep -q "^SERVE_FAILED" "$SERVE_LOG" "$READY_FILE" 2>/dev/null; then
      return 1
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      return 1
    fi
    if [ -f "$READY_FILE" ] && grep -q "^READY eproxy $mode $port" "$READY_FILE" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.25
  done
  [ "$ready" = 0 ] && return 1
  sleep 0.25
  for i in $(seq 1 12); do
    if probe_ready "$mode" "$port"; then
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.25
  done
  echo "warning: $mode on port $port did not answer probe; running load anyway" >&2
  return 0
}

parse_wrk_rps() {
  printf '%s\n' "$1" | grep -oE 'Requests/sec: *[0-9.]+' | grep -oE '[0-9.]+$' | head -1
}

parse_h2load_rps() {
  local out="$1" rps
  rps=$(printf '%s\n' "$out" | grep -E 'finished in.*req/s' | sed -E 's/.*, ([0-9.]+) req\/s.*/\1/' | head -1)
  if [ -z "$rps" ]; then
    rps=$(printf '%s\n' "$out" | awk '/^req\/s/ {print $2; exit}')
  fi
  echo "${rps:-0}"
}

drive_rps() { # mode port method path workload conns
  local mode="$1" port="$2" method="$3" path="$4" workload="$5" conns="$6" out rps
  if [ "$mode" = h1 ]; then
    if [ "$method" = POST ]; then
      out=$(wrk -t"$THREADS" -c"$conns" -d"${DUR}s" -H "Host: $BENCH_HOST" -s "$TMP/post.lua" "http://127.0.0.1:$port$path" 2>&1) || true
    else
      out=$(wrk -t"$THREADS" -c"$conns" -d"${DUR}s" -H "Host: $BENCH_HOST" "http://127.0.0.1:$port$path" 2>&1) || true
    fi
    rps=$(parse_wrk_rps "$out")
  else
    local threads streams bench
    read -r threads conns streams <<<"$(h2_bench_opts "$workload" "$conns")"
    if [ "$method" = POST ]; then
      out=$(h2load -t"$threads" -c"$conns" -m"$streams" --warm-up-time=2s -D"$DUR" \
        -H "Host: $BENCH_HOST" -d "$TMP/body.json" "https://127.0.0.1:$port$path" 2>&1) || true
    else
      out=$(h2load -t"$threads" -c"$conns" -m"$streams" --warm-up-time=2s -D"$DUR" \
        -H "Host: $BENCH_HOST" "https://127.0.0.1:$port$path" 2>&1) || true
    fi
    rps=$(parse_h2load_rps "$out")
  fi
  echo "${rps:-0}"
}

drive_rps_retry() { # mode port method path workload conns
  local mode="$1" port="$2" method="$3" path="$4" workload="$5" conns="$6" rps attempt
  for attempt in 1 2; do
    rps=$(drive_rps "$mode" "$port" "$method" "$path" "$workload" "$conns")
    if [ "$rps" != 0 ] && [ "$rps" != 0.00 ]; then
      echo "$rps"
      return 0
    fi
    if [ "$attempt" = 1 ]; then
      sleep 0.5
      conns=$((conns / 2))
      [ "$conns" -lt 4 ] && conns=4
    fi
  done
  echo "${rps:-0}"
}

run_matrix() { # mode base_port
  local mode="$1" base="$2" port wl name method path rps ready_failures=0 offset=0
  for wl in "${WORKLOADS[@]}"; do
    name="${wl%%:*}"
    method="$(echo "$wl" | cut -d: -f2)"
    path="${wl##*:}"
    port=$((base + offset))
    offset=$((offset + 1))
    if ! start_server_wait "$mode" "$port"; then
      ready_failures=$((ready_failures + 1))
      printf '%-4s %-10s %12s req/s\n' "$mode" "$name" "-"
      echo "$mode $name -" >>"$RESULTS"
      if [ -s "$SERVE_LOG" ]; then
        tail -3 "$SERVE_LOG" >&2
      fi
      continue
    fi
    conns=$(h1_bench_conns "$name" "$CONN")
    rps=$(drive_rps_retry "$mode" "$port" "$method" "$path" "$name" "$conns")
    if [ "$rps" = 0 ] || [ "$rps" = 0.00 ]; then
      stop_server
      if start_server_wait "$mode" "$port"; then
        rps=$(drive_rps_retry "$mode" "$port" "$method" "$path" "$name" "$conns")
      fi
    fi
    printf '%-4s %-10s %12s req/s\n' "$mode" "$name" "$rps"
    echo "$mode $name $rps" >>"$RESULTS"
    stop_server
  done
  if [ "$ready_failures" -gt 0 ]; then
    echo "warning: $ready_failures workload(s) skipped for $mode (server did not become ready)" >&2
  fi
}

echo
echo "##### HTTP/1.1 cleartext (wrk), ${THREADS}t/${CONN}c/${DUR}s #####"
run_matrix h1 19300

sleep 3
echo
echo "##### HTTP/2 over TLS (h2load, ${STREAMS} streams/conn) #####"
run_matrix h2 19400

sleep 1
echo
echo "##### HTTP/3 (in-VM quic_h3 driver, ${CONN} conns, ${DUR}s) #####"
ERL_CRASH_DUMP_SECONDS=0 ERL_LIBS="$BENCH_LIBS" erl -noshell -pa "$BENCH_PA" \
  -eval "pertisk_eproxy_bench:run(#{protocol => h3, connections => $CONN, duration_ms => $((DUR * 1000)), warmup_ms => 500})" \
  -eval "halt()" 2>/dev/null | grep -E "throughput|latency p50|latency p99" || echo "H3 bench produced no output (check serve log / retry)" >&2

if [ "$SWEEP" = 1 ]; then
  echo
  echo "##### Concurrency sweep (tiny GET, HTTP/1.1, wrk) #####"
  for c in 16 64 256 1024; do
    if start_server_wait h1 19500; then
      rps=$(drive_rps h1 19500 GET / tiny "$c")
      printf 'c=%-5s %12s req/s\n' "$c" "$rps"
      stop_server
    fi
  done
fi

echo
echo "##### Summary (req/s) #####"
awk '
{ rps[$1","$2]=$3; wl[$2]=1; modes[$1]=1 }
END {
  norder="tiny bytes1k bytes10k bytes100k echo"; nw=split(norder, W, " ")
  morder="h1 h2"; nm=split(morder, M, " ")
  for (mi=1; mi<=nm; mi++) {
    m=M[mi]; if (!(m in modes)) continue
    printf "\n[%s]\n", (m=="h1" ? "HTTP/1.1" : "HTTP/2 over TLS")
    printf "%-12s", "workload"
    printf "%12s\n", "req/s"
    for (wi=1; wi<=nw; wi++) {
      k=m","W[wi]
      printf "%-12s%12s\n", W[wi], (k in rps ? rps[k] : "-")
    }
  }
}' "$RESULTS"
