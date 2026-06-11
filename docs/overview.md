# Overview

**pertisk-eproxy** is a BEAM-native reverse proxy and Kubernetes ingress
controller. One Erlang application serves proxied traffic on HTTP/1.1, HTTP/2,
and optional HTTP/3, with a separate management listener for the admin REST API
and React SPA.

## When to use pertisk-eproxy

- You need an Erlang/OTP reverse proxy with HTTP/2 and HTTP/3 on the same host.
- You want a single deployment that is both edge proxy and Kubernetes ingress
  controller (ekub-based watcher, no sidecar).
- You prefer SQLite-backed site/backend config in **proxy** mode, or cluster-native
  **ingress** mode driven by standard `Ingress` + TLS `Secret` resources.
- You want Prometheus metrics, ACME DNS-01, and an admin UI without assembling
  many libraries yourself.

## Modes

| Mode | Routing source | Admin API | Typical image |
|------|----------------|-----------|---------------|
| **proxy** | SQLite `data/proxy.db` | read/write | `pertisk-eproxy/proxy` |
| **ingress** | Kubernetes Ingress + Secrets | read-only | `pertisk-eproxy/ingress` |

Set `mode` in `config/proxy.json` / `config/ingress.json`, or `PERTISK_MODE=ingress`
for the ingress image.

## Design principles

1. **Cowboy at the edge.** TCP/TLS listeners use Cowboy; HTTP/3 uses the QUIC
   gateway (`pertisk_eproxy_h3_api_gateway`) with the same routing table as HTTPS.
2. **Gun upstream pool.** Shared per-target connection pools reduce connect and
   TLS handshake cost under load.
3. **Hot reload.** `POST /api/reload` re-reads proxy JSON from disk without
   restarting the BEAM; ingress mode reconciles from Kubernetes watches.
4. **Observability without log spam.** Dedicated `:9090` Prometheus listener;
   ingress defaults disable per-request access logs on 2xx/3xx.
5. **Integrated admin.** Management API, WebSocket realtime feed, and SPA ship
   in `priv/admin/` on port 9080.

## What is in the box

| Layer | Module(s) |
|---|---|
| Application bootstrap | `pertisk_eproxy_app`, `pertisk_eproxy_sup` |
| Reverse proxy handler | `pertisk_eproxy_handler` |
| Host/path routing | `pertisk_eproxy_router` |
| HTTP/3 edge | `pertisk_eproxy_h3_api_gateway` |
| Upstream pool | `pertisk_eproxy_upstream_pool` |
| Configuration | `pertisk_eproxy_config`, `pertisk_eproxy_db` |
| Admin REST | `pertisk_eproxy_admin_handler` |
| Ingress watcher | `pertisk_ingress_watcher`, `pertisk_ingress_reconciler` |
| Metrics | `pertisk_eproxy_metrics` |

## Repository layout

| Path | Purpose |
|------|---------|
| `src/` | Erlang application |
| `config/` | `proxy.json`, `ingress.json`, `sys.config` |
| `admin/` | React admin UI (build → `priv/admin/`) |
| `deploy/helm/pertisk-eproxy/` | Ingress controller Helm chart |
| `docker/` | Proxy and ingress Dockerfiles |

See [Quickstart](quickstart.md) to run locally, or [Deploy with Helm](guides/deploy-with-helm.md)
for Kubernetes.
