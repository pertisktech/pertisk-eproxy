# QUIC Library Performance Comparison

This directory contains tools to compare performance between two QUIC implementations:

1. **benoitc/erlang_quic** (current) - Pure Erlang implementation
2. **emqx/quicer** (alternative) - NIF binding to Microsoft's msquic

## Quick Comparison

```bash
# Run HTTP/3 benchmark on both libraries (5s, 50 connections)
bench/bench_quic_compare.sh

# Longer run with more connections
DURATION=10000 CONNS=100 bench/bench_quic_compare.sh
```

## Understanding the Results

### Key Metrics

- **Throughput (req/s)**: Higher is better - measures requests per second
- **P50/P90/P99 Latency**: Lower is better - percentile response times
- **Total Requests**: Total requests completed during test duration
- **Δ%**: Percentage difference (positive = quicer faster, negative = erlang_quic faster)

### Example Output

```
Metric               | erlang_quic    | quicer         | Δ%        
---------------------|----------------|----------------|----------
Throughput (req/s)   |    8542.3 |    9123.7 |    +6.8%
Total Requests       |      42712 |      45619 |    +6.8%
P50 Latency (ms)     |      2.847 |      2.654 |    -6.8%
P90 Latency (ms)     |      4.123 |      3.891 |    -5.6%
P99 Latency (ms)     |      6.234 |      5.789 |    -7.1%
Max Latency (ms)     |     12.456 |     11.234 |    -9.8%

quicer is 6.8% faster
```

## Trade-offs

### benoitc/erlang_quic (Current)

**Pros:**
- Pure Erlang - easier to debug and patch
- Full source visibility
- Current extensive patches applied:
  - PMTU fixes
  - Fragmented TLS handshake for Chrome compatibility
  - QPACK compatibility patches
  - SNI certificate handling fixes
  - Applied via `scripts/patch-quic.sh`

**Cons:**
- Generally slower than native implementation
- Higher CPU usage for crypto operations
- More memory pressure

### emqx/quic (quicer)

**Pros:**
- Native C performance via msquic NIF
- Lower CPU overhead
- Better throughput for high-volume scenarios
- Production-proven in EMQX (major MQTT broker)
- Active development and maintenance

**Cons:**
- Native code harder to debug
- Would need to re-implement custom patches in C
- Less visibility into QUIC internals
- May have different quirks requiring new fixes

## Implementation Status

### What Works Out of the Box

Both libraries implement:
- QUIC transport (RFC 9000/9001)
- HTTP/3 client/server
- TLS 1.3
- Stream multiplexing
- Connection migration

### Current pertisk-eproxy Customizations

**Critical patches in erlang_quic** (would need porting to quicer):

1. **Fragmented TLS handshake** - Splits large handshake flights into ≤1200 byte chunks
   - Location: `_checkouts/quic/src/quic_connection.erl`
   - Why: Chrome's max_udp_payload_size=1472 requirement
   
2. **QPACK RIC=0 compatibility** - Applied via `scripts/patch-quic.sh`
   - Why: Compatibility with certain HTTP/3 clients
   
3. **SNI cert handling** - `build_server_quic_opts/1` cert chain preservation
   - Why: Per-host SNI certificate selection
   
4. **PMTU detection** - Removed hardcoded 1200 byte cap
   - Why: Proper path MTU discovery

## Migration Considerations

### To Switch to quicer:

1. Re-implement critical patches in C (msquic patches)
2. Test Chrome/Chromium H3 compatibility extensively
3. Verify SNI certificate selection works
4. Validate production traffic patterns
5. Update `scripts/patch-quic.sh` equivalent

### Hybrid Approach:

- Use quicer for high-throughput edge routing
- Keep erlang_quic for development/debugging
- Profile-based selection via rebar3 profiles

## Benchmarking Details

The comparison script:
1. Compiles both profiles separately
2. Runs identical HTTP/3 workloads
3. Measures throughput and latency percentiles
4. Reports percentage differences

Default test: 50 concurrent connections, 5 second duration, "tiny" workload (GET /)

## Related Files

- `bench_quic_compare.sh` - Main comparison script
- `rebar.config` - Profile definitions (`bench` vs `bench_quicer`)
- `pertisk_eproxy_bench.erl` - Benchmark harness
- `scripts/patch-quic.sh` - Current erlang_quic patches

## Notes

- Results may vary based on CPU, network conditions, and OS
- Run multiple times and average for consistent results
- Both libraries are actively maintained
- Consider feature parity, not just raw performance
- Migration cost may outweigh performance gains
