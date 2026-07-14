# Tune ingress throughput

Recommended settings for Kubernetes ingress at scale.

## HTTP/3 first (what we k6)

Reports under `pertisk-k6-proxy/reports/proxy` come from `tests/api-health-http3.js` (xk6-http3), not H2. Multi-replica + `Cluster` ETP breaks QUIC stickiness and tanks TPS.

| Lever | Setting | Why |
|---|---|---|
| Replicas | `replicaCount: 1` | UDP LB is not connection-sticky |
| Service | `externalTrafficPolicy: Local` | Keep QUIC on one node/pod |
| CPU | limits `4000m`, no `+S` pin | BEAM follows cgroup; old `+S 2:2` capped schedulers |
| QUIC pool | `h3_quic_pool_size: 32` | Parallel `gen_udp` acceptors |
| CC | `h3_congestion_control: bbr` | Better under concurrent streams |
| UDP size | `h3_max_udp_payload_size: 1472` + `h3_pmtu_enabled: true` | Fewer packets on clean paths |
| Logs | `proxy_access_log` / `health_access_log: false` | CPU for packets, not logs |

Deploy overlay (`values-h3-perf.yaml`, default via `./deploy/erlang.sh`):

```bash
VERSION=0.5.xx ./deploy/erlang.sh
# H3_PERF=1 REPLICA_COUNT=1 by default
```

Re-bench:

```bash
WARMUP_VUS=0 VUS=100 DURATION=60s REPORT_DIR=reports/proxy \
  BASE_URL=https://admin.erlang.pertisk.com ./k6 run tests/api-health-http3.js
```

SQLite **proxy mode** seed: `config/proxy.json` (same H3 keys). H2-only overlay: `PROXY_PERF=1 H3_PERF=0` → `values-proxy-perf.yaml`.

## Defaults (Helm `values.yaml`)

```yaml
controller:
  config:
    proxy_access_log: false
    health_access_log: false
    log_level: warn
    upstream_pool_size: 256
    h3_max_streams: 2048
    h3_stream_receive_window: 8388608
    h3_conn_receive_window: 67108864
```

## Key levers

| Area | Setting | Notes |
|------|---------|-------|
| Access logs | `proxy_access_log: false` | Largest CPU win at high TPS |
| Health logs | `health_access_log: false` | Keep off under k6 |
| Upstream pool | `upstream_pool_size: 256` | Gun idle connections per host |
| HTTP/3 LB | `replicaCount: 1` + `externalTrafficPolicy: Local` | See **HTTP/3 first** |
| HTTP/3 | `h3_quic_pool_size`, CC, windows | `values-h3-perf.yaml` |
| CPU | Pod `resources.limits.cpu` | BEAM schedulers from cgroup |

## HTTP/3 JSON defaults

| Key | Bench (`values-h3-perf`) | Notes |
|-----|--------------------------|-------|
| `h3_quic_pool_size` | 32 | SO_REUSEPORT acceptor pool |
| `h3_congestion_control` | `bbr` | Also `cubic` / `newreno` |
| `h3_max_udp_payload_size` | 1472 | Use 1200 on blackhole paths |
| `h3_max_streams` | 4096 | |
| `h3_stream_receive_window` | 16 MiB | |
| `h3_conn_receive_window` | 128 MiB | |
| `upstream_pool_idle_timeout_secs` | 90 | |

## Metrics over logs

Use Prometheus on `:9090/metrics` for TPS — not access logs.

See [Prometheus metrics](prometheus-metrics.md).

## Cowboy / OTP performance (H2c, static files)

pertisk-eproxy tracks **Cowboy master** (2.13+). **Proxy** HTTP/1.1 and HTTPS listeners set `dynamic_buffer => {1024, 131072}` for H2c/large-body workloads ([OTP #9423](https://github.com/erlang/otp/issues/9423)). Management (`:9080`), metrics, and the **HTTP/3 API gateway** (erlang_quic) do not use this Cowboy option.

**k6 `GET /api/health` over HTTP/3** is served by `try_h3_benchmark_fast_path/4` in `pertisk_eproxy_h3_api_gateway` (constant `{"status":"ok"}` body, no router/metrics/access log). Tuning Cowboy `dynamic_buffer` does not affect that path; compare runs on the same image with 3–5 k6 iterations before attributing a regression.

| Symptom | Likely cause | Mitigation |
|---------|--------------|------------|
| H3 cancel / low TPS | Multi-replica UDP LB | `values-h3-perf.yaml` / `REPLICA_COUNT=1` |
| Low RPS serving small static files | `cowboy_static` → `file_server_2` queue | Do not use `cowboy_static` on hot paths; HTTP/3 admin assets use raw `file:read_file/2`; proxy traffic goes through `pertisk_eproxy_handler` |
| H2c much slower than H2+TLS | Small TCP segments + old Cowboy buffer behavior | Already on Cowboy 2.13+ with `dynamic_buffer`; prefer TLS termination on the proxy for production |
| High CPU, flat RPS at load | Access logs, Lager JSON, admin ring buffer | `proxy_access_log: false`, `log_level: warn` (see table above) |
| Admin UI on `:9080` under load | `cowboy_static` for `/assets/*` | Expected for management only; not on the ingress hot path |

**Do not** set a fixed Ranch `buffer` transport option unless you benchmark both ways — it disables `dynamic_buffer`.

**Benchmark on the runner:** `make bench-compare` or `pertisk_eproxy_bench:run/1` on the same host before/after config changes. Use `recon:proc_count(message_queue_len, 10)` if you suspect `file_server_2` or a single process bottleneck.

**VM** (`config/vm.args`): `+A 64`, `+Q 65536`, `+K true`; schedulers follow cgroup CPU in Kubernetes (do not use invalid `+S auto`).
