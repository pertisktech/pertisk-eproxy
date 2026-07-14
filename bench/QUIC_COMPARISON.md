# QUIC Library Performance Comparison

This directory contains tools to compare performance between two QUIC implementations:

1. **emqx/quicer** (**default**) — NIF binding to Microsoft's MsQuic via Cowboy `start_quic/3`
2. **benoitc/erlang_quic** (fallback) — Pure Erlang; enable with `h3_api_gateway_enabled: true`

## Runtime switch

| Config | Backend |
|--------|---------|
| `quic_enabled: true`, `h3_api_gateway_enabled: false` | Cowboy + quicer (default) |
| `quic_enabled: true`, `h3_api_gateway_enabled: true` | erlang_quic `quic_h3` gateway |

Build requires Cowboy compiled with `{d, 'COWBOY_QUICER', 1}` and the `quicer` dep (see `rebar.config`). Env `COWBOY_QUICER=1` alone is not enough under rebar3.

## Quick Comparison

```bash
# Run HTTP/3 benchmark on both libraries (5s, 50 connections)
bench/bench_quic_compare.sh

# Longer run with more connections
DURATION=10000 CONNS=100 bench/bench_quic_compare.sh
```

## Related Files

- `bench_quic_compare.sh` — Main comparison script
- `rebar.config` — `quicer` + Cowboy `COWBOY_QUICER` define; `bench` / `bench_quicer` profiles
- `pertisk_eproxy_bench.erl` — Benchmark harness
- `scripts/verify-release-quicer.sh` — Assert `cowboy:start_quic/3` in release
- `scripts/bundle-msquic-for-rpm.sh` — Ship MsQuic `.so` into RPM `lib/runtime`
- `scripts/patch-quic.sh` — erlang_quic patches (fallback gateway only)
