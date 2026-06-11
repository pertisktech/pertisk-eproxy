# Architecture

pertisk-eproxy is a single OTP application with Cowboy listeners, optional QUIC
HTTP/3, Gun upstream pools, and an optional Kubernetes ingress controller.

## High-level diagram

```
                    ┌─────────────────────────────────────┐
                    │         pertisk-eproxy BEAM         │
                    │                                     │
  Clients ──HTTP──► │  Cowboy :8080 / :8443               │
         ──QUIC──► │  H3 gateway :8443/udp                │
                    │         │                           │
                    │         ▼                           │
                    │  pertisk_eproxy_handler / H3 gw     │
                    │         │                           │
                    │         ▼                           │
                    │  pertisk_eproxy_upstream_pool       │
                    │         │                           │
                    │         ▼ Gun                       │
                    └─────────┼───────────────────────────┘
                              │
                              ▼
                         Upstream apps

  Admins ──────────► Cowboy :9080 (REST + SPA)
  Prometheus ──────► :9090 /metrics
```

## Major components

| Component | Role |
|-----------|------|
| `pertisk_eproxy_app` | Starts supervisors, listeners, metrics |
| `pertisk_eproxy_handler` | Cowboy reverse proxy (HTTP/1.1, H2 on TLS) |
| `pertisk_eproxy_h3_api_gateway` | HTTP/3 edge with same routing |
| `pertisk_eproxy_config` | In-memory config; SQLite or ingress JSON |
| `pertisk_ingress_watcher` | Watches Ingress + TLS Secrets (ingress mode) |
| `pertisk_eproxy_admin_handler` | Management REST API |

## Listeners

| Listener | Default port | Purpose |
|----------|--------------|---------|
| HTTP | 8080 | Cleartext proxy |
| HTTPS | 8443 | TLS proxy (HTTP/2) |
| QUIC | 8443/udp | HTTP/3 |
| Management | 9080 | Admin API + SPA |
| Metrics | 9090 | Prometheus |

Ports are configurable in JSON (`http_port`, `https_port`, `management_port`, etc.).

## Further reading

- [Proxy vs ingress mode](proxy-vs-ingress.md)
- [Request lifecycle](request-lifecycle.md)
- [Kubernetes ingress](kubernetes-ingress.md)
