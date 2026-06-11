# Set log level and access logging

## Application log level

| Key / env | Default | Values |
|-----------|---------|--------|
| `log_level` | `info` | `debug`, `info`, `warn`, `error` |
| `PERTISK_LOG_LEVEL` | — | Overrides JSON |

Helm ingress: `controller.config.log_level` or `logging.level`.

## Proxy access logging

Every proxied 2xx/3xx can write to the admin ring buffer and Lager JSON. At
ingress scale, disable for throughput:

| Key / env | Ingress default |
|-----------|-----------------|
| `proxy_access_log` | `false` |
| `PERTISK_PROXY_ACCESS_LOG` | — |

4xx/5xx are still logged when `proxy_access_log` is `false`.

## Health probe logging

| Key | Default |
|-----|---------|
| `health_access_log` | `false` |
| `health_access_log_sample` | `0` |

Keep off under load tests and many replicas.

## See also

- [Tune ingress throughput](tune-ingress-throughput.md)
