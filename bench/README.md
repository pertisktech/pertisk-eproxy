# pertisk-eproxy benchmarks

`pertisk_eproxy_bench` drives keep-alive load through the reverse proxy to a
local reference upstream (`bench_upstream_h`), over HTTP/1.1, HTTP/2 (TLS), or
HTTP/3, and reports latency percentiles and throughput. It also implements a
>10% p99 regression gate.

## Run

```
rebar3 as bench shell
1> pertisk_eproxy_bench:run().                       %% H1, defaults
2> pertisk_eproxy_bench:run(#{protocol => h3}).
3> pertisk_eproxy_bench:run_all(#{connections => 100, duration_ms => 5000}).
```

Run it interactively (the example above) rather than with `halt/0`: `run/1`
stops listeners cleanly in its `after` clause, whereas halting the VM
mid-teardown logs spurious connection crashes.

Options: `protocol` (`h1` | `h2` | `h3`, default `h1`), `workload`
(`tiny` | `bytes1k` | `bytes10k` | `bytes100k` | `echo`, default `tiny`),
`connections` (default 50), `duration_ms` (3000), `warmup_ms` (500),
`port` (0 = ephemeral).

`run/0,1` prints a report and returns a metrics map:

```erlang
#{protocol => h1, workload => tiny, connections => 50, duration_ms => 3000,
  requests => N, reconnects => R, throughput_rps => F,
  p50_us => _, p90_us => _, p99_us => _, max_us => _}
```

`reconnects` counts connections re-established mid-run. All three protocols
keep one connection per worker and report 0 under steady load; a non-zero count
means requests were failing and the worker had to reconnect.

## Workload matrix (`bench/compare.sh`)

External clients (`wrk` for H1, `h2load` for H2) drive the proxy out of
process. Each server boots on its own port with `pertisk_eproxy_bench:serve/2`.
Requests use `Host: bench.local` so traffic routes through the proxy to the
reference upstream.

| Workload  | request            | what it stresses                          |
|-----------|--------------------|-------------------------------------------|
| `tiny`    | `GET /`            | accept + framing + proxy hop overhead     |
| `bytes1k` | `GET /bytes/1024`  | response write path at 1 KiB              |
| `bytes10k`| `GET /bytes/10240` | response write path at 10 KiB             |
| `bytes100k`| `GET /bytes/102400`| response write path at 100 KiB           |
| `echo`    | `POST /echo`       | body read + proxy + upstream echo         |

```
bench/compare.sh                       # full matrix, 4 threads, 64 conns, 10s
DUR=20 CONN=128 bench/compare.sh
SWEEP=1 bench/compare.sh               # also a concurrency sweep (16/64/256/1024)
```

Requires `wrk`, `h2load`, `curl`, `rebar3`, and `openssl` on the PATH.

Heavy workloads (`bytes10k`, `bytes100k`, `echo`) use lower client concurrency and
a 2s h2load warm-up to avoid flaky connection storms through the TLS proxy.
Bench mode enables `upstream_loopback_pool_enabled` and production-aligned pool/H3
settings so loopback upstreams reuse Gun keep-alive (matching remote-backend behavior).
If a row reports `0` req/s, retry once; persistent zeros usually mean the
listener did not become ready (see stderr tail from `serve.log`).

HTTP/3 uses the in-VM `quic_h3` driver (same as [livery bench](https://github.com/benoitc/livery/tree/main/bench));
external h3 load tools do not interoperate cleanly with the self-signed QUIC
listener, so H3 figures are not directly comparable to the external H1/H2 runs.

## p99 regression gate

Capture a baseline on your benchmark host and compare future runs:

```erlang
Baseline = pertisk_eproxy_bench:run(#{connections => 100, duration_ms => 10000}),
%% ... later, on the same host ...
Current  = pertisk_eproxy_bench:run(#{connections => 100, duration_ms => 10000}),
{ok, _} = pertisk_eproxy_bench:compare(Baseline, Current).
```

`compare/2` returns `{ok, _}` when the current p99 is within 110% of the
baseline p99, or `{regressed, Detail}` otherwise. Percentile numbers are
host-specific, so generate the baseline where the gate runs rather than
committing fixed numbers.

## Makefile shortcuts

```
make bench          # compile bench profile
make bench-shell    # rebar3 as bench shell
make bench-compare  # run bench/compare.sh
```

## Stress vs. benchmark

This harness measures throughput and latency under load. Use the EUnit suite
(`make test`) for correctness and concurrency invariants; use this bench
harness for heavy, long-running soak testing and before/after performance
comparisons on the same host.

Absolute req/s numbers are host-specific. Use them only as a same-host
before/after baseline, not as cross-environment targets.
