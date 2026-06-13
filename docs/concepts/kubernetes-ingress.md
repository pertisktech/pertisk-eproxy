# Kubernetes ingress

In **ingress** mode, pertisk-eproxy reconciles standard `networking.k8s.io/v1`
Ingress resources (and optionally Gateway API `HTTPRoute` objects) into
in-memory sites and backends.

For the full phased feature list (annotations, auth, rate limits, Gateway API),
see [ROADMAP_PHASES.md](../ROADMAP_PHASES.md).

## Reconciliation flow

1. `pertisk_ingress_watcher` watches Ingress and TLS Secret objects (ekub).
2. `pertisk_ingress_reconciler` transforms each Ingress into site/backend entries.
3. When enabled, `pertisk_gateway_reconciler` merges `HTTPRoute` resources.
4. `pertisk_eproxy_config:sync_ingress/2` updates the hot config (no SQLite).
5. TLS material from Secrets is written under `data/` for listener reload.
6. `pertisk_ingress_leader` holds the coordination lease; the **leader** patches
   Ingress `.status` (load balancer + conditions). All replicas reconcile config.

## Ingress class

Only Ingresses with `spec.ingressClassName` matching `pertisk-eproxy` (Helm default)
are reconciled. Override via `ingress.className` in Helm values.

## Cross-namespace backends

Annotations (preferred `pertisk.io/`; legacy `pertisk.tech/` still supported):

- `pertisk.io/backend-namespace` — default backend namespace
- `pertisk.io/backend-namespaces` — JSON map of service name → namespace

## Routing and backends

| Annotation | Purpose |
|------------|---------|
| `pertisk.io/rewrite-target` | Rewrite matched path prefix |
| `pertisk.io/load-balancer` | `round_robin`, `least_connections`, `ip_hash` |
| `pertisk.io/health-path` | Active health check path for upstreams |
| `pertisk.io/resource-upstreams` | Map Ingress resource backends to `host:port` |

## Security and traffic shaping

| Annotation | Purpose |
|------------|---------|
| `pertisk.io/auth-url` | External auth subrequest before proxying |
| `pertisk.io/rate-limit-rps` | Per-Ingress requests per second |
| `pertisk.io/rate-limit-burst` | Per-Ingress burst allowance |

Global rate limits are also available via proxy config:
`rate_limit_enabled`, `rate_limit_rps`, `rate_limit_burst`.

## HTTP/3 and streaming

| Annotation | Purpose |
|------------|---------|
| `pertisk.io/advertise-http3` | Advertise HTTP/3 via Alt-Svc |
| `pertisk.io/sse-early-flush` | SSE / EventSource early flush |
| `pertisk.io/sse-early-flush-paths` | Per-path SSE flush overrides |

## Gateway API (optional)

Enable with Helm `ingress.gatewayApiEnabled: true`. This installs a
`GatewayClass` named like `ingress.className` (default `pertisk-eproxy`) so
`kubectl get gatewayclass` lists the controller. HTTPRoutes must include:

```yaml
metadata:
  annotations:
    pertisk.io/gateway-class: pertisk-eproxy
```

## Probes and status

| Path | Purpose |
|------|---------|
| `/api/ingress/live` | Liveness |
| `/api/ingress/ready` | Readiness |
| `/api/ingress/status` | Controller status snapshot |

Ingress objects receive `.status.loadBalancer` from the chart Service when the
pod holds the leader lease (`PERTISK_K8S_PUBLISH_SERVICE`).

## Further reading

- [ROADMAP_PHASES.md](../ROADMAP_PHASES.md) — phased implementation status
- [K8S_INGRESS_IMPLEMENTATION.md](../K8S_INGRESS_IMPLEMENTATION.md) — design notes
- [Deploy with Helm](../guides/deploy-with-helm.md)
- [Prometheus metrics](../guides/prometheus-metrics.md)
