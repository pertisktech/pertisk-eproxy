# Tune ingress throughput

Recommended settings for Kubernetes ingress at scale.

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
| HTTP/3 | `h3_max_streams`, window sizes | Match expected concurrency |
| CPU | Pod `resources.limits.cpu` | BEAM schedulers from cgroup |
| HTTP/3 LB | `replicaCount: 1` or `externalTrafficPolicy: Local` | UDP is often non-sticky |

## HTTP/3 JSON defaults

| Key | Default |
|-----|---------|
| `h3_max_streams` | 2048 |
| `h3_stream_receive_window` | 8 MiB |
| `h3_conn_receive_window` | 64 MiB |
| `upstream_pool_idle_timeout_secs` | 90 |

## Metrics over logs

Use Prometheus on `:9090/metrics` for TPS — not access logs.

See [Prometheus metrics](prometheus-metrics.md).
