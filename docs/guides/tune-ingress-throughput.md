# Tune ingress throughput

Recommended settings for Kubernetes ingress at scale.

## HTTP/3 first (what we k6)

Default edge stack is **erlang_quic gateway** (`quic_enabled: true`, `h3_api_gateway_enabled: true`).
Set `h3_api_gateway_enabled: false` for Cowboy + quicer (MsQuic) A-B — slower on 1-vCPU health benches in our k6 runs.

Reports under `pertisk-k6-proxy/reports/proxy` come from `tests/api-health-http3.js` (xk6-http3).

| Lever | Setting | Why |
|---|---|---|
| Backend | `h3_api_gateway_enabled: true` | erlang_quic `quic_h3` gateway (faster local health) |
| A-B | `h3_api_gateway_enabled: false` | Cowboy+quicer (MsQuic NIF) |
| Replicas | `replicaCount: 1` | UDP LB is not connection-sticky |
| Service | `externalTrafficPolicy: Local` | Keep QUIC on one node/pod |
| CPU | match Rust / raise with load | BEAM + MsQuic both need cores |
| Logs | `proxy_access_log` / `health_access_log: false` | CPU for packets, not logs |

Deploy overlay (`values-h3-perf.yaml`, default via `./deploy/erlang.sh`):

```bash
VERSION=0.5.xx ./deploy/erlang.sh
```

Default performance path is erlang_quic; Cowboy+quicer remains available for A-B on glibc RPM hosts.

Re-bench:

```bash
WARMUP_VUS=0 VUS=100 DURATION=60s REPORT_DIR=reports/proxy \
  BASE_URL=https://admin.erlang.pertisk.com ./k6 run tests/api-health-http3.js
```

## Defaults (Helm `values.yaml`)

```yaml
controller:
  config:
    proxy_access_log: false
    health_access_log: false
    log_level: warn
    upstream_pool_size: 256
```

## Key levers

| Area | Setting | Notes |
|------|---------|-------|
| Access logs | `proxy_access_log: false` | Largest CPU win at high TPS |
| Health logs | `health_access_log: false` | Keep off under k6 |
| HTTP/3 backend | `h3_api_gateway_enabled` | false=quicer, true=erlang_quic |
| HTTP/3 LB | `replicaCount: 1` + `externalTrafficPolicy: Local` | Sticky UDP |
| CPU | Pod `resources.limits.cpu` | BEAM schedulers from cgroup |

## Metrics over logs

Use Prometheus on `:9090/metrics` for TPS — not access logs.

See [Prometheus metrics](prometheus-metrics.md).

## Cowboy / OTP performance (H2c, static files)

pertisk-eproxy tracks **Cowboy master** (2.13+). **Proxy** HTTP/1.1 and HTTPS listeners set `dynamic_buffer => {1024, 131072}` for H2c/large-body workloads ([OTP #9423](https://github.com/erlang/otp/issues/9423)).

**k6 `GET /api/health` over HTTP/3** (Cowboy+quicer) hits the same proxy routes as HTTPS (`pertisk_eproxy_handler` / health cache). The legacy erlang_quic gateway still has `try_h3_benchmark_fast_path/4` when enabled.

| Symptom | Likely cause | Mitigation |
|---------|--------------|------------|
| H3 cancel / low TPS | Multi-replica UDP LB | `values-h3-perf.yaml` / `REPLICA_COUNT=1` |
| `start_quic/3` missing | Cowboy built without `COWBOY_QUICER` | rebar cowboy override `{d,'COWBOY_QUICER',1}` + quicer dep |
| libmsquic load fail | RPM LD path | `lib/runtime` via `bundle-msquic-for-rpm.sh` |
| High CPU, flat RPS | Access logs | `proxy_access_log: false`, `log_level: warn` |

**VM** (`config/vm.args`): `+A 64`, `+Q 65536`, `+K true`; schedulers follow cgroup CPU in Kubernetes.
