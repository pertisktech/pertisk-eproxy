# Prometheus metrics

## Dedicated listener

| Key / env | Default |
|-----------|---------|
| `metrics_port` | `9090` |
| `metrics_addr` | `0.0.0.0` |
| `metrics_enabled` | `true` |
| `PERTISK_METRICS_ADDR` | — |

```bash
curl -s http://127.0.0.1:9090/metrics
```

## Legacy endpoint

`GET /api/metrics` on the management port still works. Prefer `:9090` for
ServiceMonitor scrapes.

## Helm

`metrics.enabled`, `metrics.serviceMonitor` in `deploy/helm/pertisk-eproxy/values.yaml`.

## Admin UI

`GET /api/stats` returns JSON counters for charts (not Prometheus format).
