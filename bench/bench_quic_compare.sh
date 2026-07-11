#!/usr/bin/env bash
# Compare performance between benoitc/erlang_quic and emqx/quic (quicer)
#
# Usage:
#   bench/bench_quic_compare.sh                 # Quick H3 comparison
#   DURATION=10000 bench/bench_quic_compare.sh  # Longer run
#   CONNS=100 bench/bench_quic_compare.sh       # More connections
#   Includes optional Cowboy QUIC H3 when available in bench_quicer profile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

DURATION="${DURATION:-5000}"
CONNS="${CONNS:-50}"
WARMUP="${WARMUP:-500}"

echo "==============================================="
echo "QUIC Library Performance Comparison"
echo "Duration: ${DURATION}ms, Connections: $CONNS"
echo "==============================================="
echo ""

# Compile both profiles
echo "==> Compiling erlang_quic profile (bench)..."
if ! rebar3 as bench compile > /tmp/bench_compile.log 2>&1; then
  echo "Failed to compile bench profile. See /tmp/bench_compile.log"
  exit 1
fi

echo "==> Compiling quicer profile (bench_quicer)..."
if ! rebar3 as bench_quicer compile > /tmp/bench_quicer_compile.log 2>&1; then
  echo "Failed to compile bench_quicer profile. See /tmp/bench_quicer_compile.log"
  exit 1
fi

# Function to run benchmark for a given profile
run_bench() {
  local profile=$1
  local label=$2
  local output_file=$3
  local h3_impl=${4:-gateway}
  
  echo "==> Running benchmark with $label..."
  
  # Build code path from all lib directories
  local code_path=""
  for dir in _build/$profile/lib/*/ebin; do
    if [ -d "$dir" ]; then
      code_path="$code_path -pa $dir"
    fi
  done
  
  # Add bench modules from extra_src_dirs
  if [ -d "_build/$profile/lib/pertisk_eproxy/bench" ]; then
    code_path="$code_path -pa _build/$profile/lib/pertisk_eproxy/bench"
  fi
  
  erl $code_path \
      -noshell -noinput \
      -eval "
        Opts = #{
          protocol => h3,
          h3_impl => $h3_impl,
          workload => tiny,
          connections => $CONNS,
          duration_ms => $DURATION,
          warmup_ms => $WARMUP
        },
        try
          Metrics = pertisk_eproxy_bench:run(Opts),
          io:format(\"~nMETRICS: ~p~n\", [Metrics]),
          ok = file:write_file(\"$output_file\", io_lib:format(\"~p.~n\", [Metrics])),
          io:format(\"Results written to $output_file~n\"),
          halt(0)
        catch
          E:R:ST ->
            io:format(standard_error, \"Benchmark failed: ~p:~p~n~p~n\", [E, R, ST]),
            halt(1)
        end.
      " \
      2>&1 | tee "/tmp/${profile}_bench.log"
  
  local exit_code=${PIPESTATUS[0]}
  
  if [ $exit_code -ne 0 ]; then
    echo "Error: Benchmark failed with exit code $exit_code for $label"
    return 1
  fi
  
  if [ ! -f "$output_file" ]; then
    echo "Error: Benchmark output file not created for $label"
    return 1
  fi
}

# Run both benchmarks
ERLANG_QUIC_OUT="/tmp/erlang_quic_metrics.erl"
QUICER_OUT="/tmp/quicer_metrics.erl"
COWBOY_QUIC_OUT="/tmp/cowboy_quic_metrics.erl"
COWBOY_QUIC_AVAILABLE=0

run_bench "bench" "benoitc/erlang_quic (gateway)" "$ERLANG_QUIC_OUT" "gateway"
echo ""
run_bench "bench_quicer" "emqx/quic (gateway)" "$QUICER_OUT" "gateway"
echo ""
if run_bench "bench_quicer" "cowboy HTTP/3 (quicer)" "$COWBOY_QUIC_OUT" "cowboy_quic"; then
  COWBOY_QUIC_AVAILABLE=1
else
  echo "Warning: Cowboy HTTP/3 benchmark unavailable in this build; continuing with gateway comparison only."
fi
echo ""

# Compare results
echo "==============================================="
echo "COMPARISON RESULTS"
echo "==============================================="

erl -noinput -eval "
  {ok, [ErlangQuic]} = file:consult(\"$ERLANG_QUIC_OUT\"),
  {ok, [Quicer]} = file:consult(\"$QUICER_OUT\"),
  CowboyQuicMaybe =
    case file:consult(\"$COWBOY_QUIC_OUT\") of
      {ok, [CowboyMetrics]} -> {ok, CowboyMetrics};
      _ -> unavailable
    end,
  
  EQ_RPS = maps:get(throughput_rps, ErlangQuic),
  EQ_P50 = maps:get(p50_us, ErlangQuic) / 1000,
  EQ_P90 = maps:get(p90_us, ErlangQuic) / 1000,
  EQ_P99 = maps:get(p99_us, ErlangQuic) / 1000,
  EQ_MAX = maps:get(max_us, ErlangQuic) / 1000,
  EQ_REQS = maps:get(requests, ErlangQuic),
  
  QC_RPS = maps:get(throughput_rps, Quicer),
  QC_P50 = maps:get(p50_us, Quicer) / 1000,
  QC_P90 = maps:get(p90_us, Quicer) / 1000,
  QC_P99 = maps:get(p99_us, Quicer) / 1000,
  QC_MAX = maps:get(max_us, Quicer) / 1000,
  QC_REQS = maps:get(requests, Quicer),
  
  DiffRPS = ((QC_RPS - EQ_RPS) / EQ_RPS) * 100,
  DiffP50 = ((QC_P50 - EQ_P50) / EQ_P50) * 100,
  DiffP90 = ((QC_P90 - EQ_P90) / EQ_P90) * 100,
  DiffP99 = ((QC_P99 - EQ_P99) / EQ_P99) * 100,
  
  io:format(\"~n\"),
  io:format(\"Metric               | erlang_quic    | quicer         | Delta%    ~n\"),
  io:format(\"---------------------|----------------|----------------|----------~n\"),
    io:format(\"Throughput (req/s)   | ~10.1f | ~10.1f | ~8.1f%~n\", [EQ_RPS, QC_RPS, DiffRPS]),
    io:format(\"Total Requests       | ~10b | ~10b | ~8.1f%~n\", [EQ_REQS, QC_REQS, ((QC_REQS - EQ_REQS) / EQ_REQS) * 100]),
    io:format(\"P50 Latency (ms)     | ~10.3f | ~10.3f | ~8.1f%~n\", [EQ_P50, QC_P50, DiffP50]),
    io:format(\"P90 Latency (ms)     | ~10.3f | ~10.3f | ~8.1f%~n\", [EQ_P90, QC_P90, DiffP90]),
    io:format(\"P99 Latency (ms)     | ~10.3f | ~10.3f | ~8.1f%~n\", [EQ_P99, QC_P99, DiffP99]),
    io:format(\"Max Latency (ms)     | ~10.3f | ~10.3f | ~8.1f%~n\", [EQ_MAX, QC_MAX, ((QC_MAX - EQ_MAX) / EQ_MAX) * 100]),
  io:format(\"~n\"),
  
  Winner = if
    QC_RPS > EQ_RPS * 1.05 -> \"quicer is ~.1f% faster\";
    EQ_RPS > QC_RPS * 1.05 -> \"erlang_quic is ~.1f% faster\";
    true -> \"Performance is comparable (~.1f% difference)\"
  end,
  io:format(\"~n\"),
  io:format(Winner ++ \"~n~n\", [abs(DiffRPS)]),
  
  % Write summary to file
  Summary = #{
    erlang_quic => ErlangQuic,
    quicer => Quicer,
    cowboy_quic => CowboyQuicMaybe,
    diff_rps_percent => DiffRPS,
    diff_p50_percent => DiffP50,
    diff_p99_percent => DiffP99
  },

  case CowboyQuicMaybe of
    {ok, CowboyQuic} ->
      CB_RPS = maps:get(throughput_rps, CowboyQuic),
      CB_P50 = maps:get(p50_us, CowboyQuic) / 1000,
      CB_P90 = maps:get(p90_us, CowboyQuic) / 1000,
      CB_P99 = maps:get(p99_us, CowboyQuic) / 1000,
      CB_MAX = maps:get(max_us, CowboyQuic) / 1000,
      CB_REQS = maps:get(requests, CowboyQuic),
      io:format(\"Cowboy HTTP/3 (quicer):~n\"),
      io:format(\"  Throughput (req/s): ~.1f (vs erlang_quic gateway: ~.1f%)~n\", [
        CB_RPS,
        ((CB_RPS - EQ_RPS) / EQ_RPS) * 100
      ]),
      io:format(\"  Total Requests: ~b~n\", [CB_REQS]),
      io:format(\"  P50/P90/P99/Max (ms): ~.3f / ~.3f / ~.3f / ~.3f~n~n\", [
        CB_P50,
        CB_P90,
        CB_P99,
        CB_MAX
      ]);
    unavailable ->
      io:format(\"Cowboy HTTP/3 (quicer): unavailable in this build/profile~n~n\")
  end,

  file:write_file(\"/tmp/quic_comparison.erl\", io_lib:format(\"~p.~n\", [Summary])),
  
  halt(0).
"

echo "==============================================="
echo "Full results saved to:"
echo "  - /tmp/erlang_quic_metrics.erl"
echo "  - /tmp/quicer_metrics.erl"
if [ "$COWBOY_QUIC_AVAILABLE" -eq 1 ]; then
  echo "  - /tmp/cowboy_quic_metrics.erl"
fi
echo "  - /tmp/quic_comparison.erl"
echo "==============================================="
