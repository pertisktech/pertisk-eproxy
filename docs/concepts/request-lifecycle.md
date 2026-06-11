# Request lifecycle

How a proxied request flows through pertisk-eproxy.

## TCP / TLS (Cowboy)

1. Cowboy accepts on `http_port` or `https_port`.
2. `pertisk_eproxy_handler:init/2` records timing and protocol (`proto` label).
3. Host and path match a **site** route via `pertisk_eproxy_router`.
4. Backend selection (`pertisk_eproxy_lb`) picks an upstream from the pool.
5. `pertisk_eproxy_upstream_pool:checkout/5` returns a Gun connection.
6. Request is forwarded; response streamed back (with optional compression).
7. Access log and Prometheus counters updated (if enabled).
8. `Alt-Svc` may advertise HTTP/3 on HTTPS responses.

## HTTP/3 (QUIC)

1. QUIC listener in `pertisk_eproxy_h3_api_gateway`.
2. Management paths (`/api/*`, SPA) may be handled in-process via
   `pertisk_eproxy_h3_local_admin` (no hop to :9080).
3. Other hosts use the same site/backend tables as TCP HTTPS.
4. Upstream Gun options include HTTP/2 where TLS allows connection sharing.

## Management API

1. Cowboy management listener on `management_port` (default 9080).
2. `pertisk_eproxy_admin_handler` dispatches `/api/*` routes.
3. Static SPA from `priv/admin/` at `/`.
4. WebSocket realtime at `/api/realtime`.

## Health and metrics

- `GET /api/health` — aggregated health (cached by `pertisk_eproxy_health_cache`)
- `GET /metrics` on `:9090` — Prometheus text exposition
