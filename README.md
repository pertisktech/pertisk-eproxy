# pertisk-eproxy

Erlang/OTP reverse proxy built on **Cowboy**, with an optional **management listener** (REST + Web UI), **Prometheus** metrics, **HTTP/2** on TLS, and optional **HTTP/3** paths (H3 API gateway / QUIC where enabled in the build).

## Requirements

- Erlang/OTP (see `rebar.config` for typical versions used in CI)
- `rebar3`
- Optional: Node.js 20+ to rebuild the admin UI (`admin/` → `priv/admin/`)

## Build

```bash
make compile
# or
rebar3 compile
```

Optional QUIC-related compile flags are documented in the `Makefile` (`COWBOY_QUICER`, `COWBOY_QUIC`).

## Run (development)

```bash
rebar3 shell
```

Application config defaults live in `config/sys.config` (e.g. `admin_auth`, ACME-related keys). Proxy routing, sites, backends, and listener ports are loaded from the JSON file pointed to by `config_file` (default `config/proxy.json`). See `README_SQLITE.md` for database-backed certificate and DNS provider storage.

## Modes

- **`proxy_admin`** (typical): management port serves the **React admin UI** at `/` and JSON under `/api/…`.
- **`proxy`**: management port is API-only; **`GET /`** returns a small JSON object with a short `endpoints` list (see `pertisk_eproxy_admin_handler.erl`).

`mode` is part of the proxy JSON configuration (`proxy` vs `proxy_admin`).

## Management listener

Default bind is **`127.0.0.1:9080`** (`management_addr`, `management_port` in config). REST paths use the **`/api/…`** prefix on that listener (e.g. `http://127.0.0.1:9080/api/config`).

### Authentication

- **`admin_auth`** in `config/sys.config`: `disabled` (open API) or `local` (Bearer session after `POST /api/auth/login`).
- When `local` is enabled, most `/api/*` routes require `Authorization: Bearer <token>`.
- Unauthenticated access is still allowed for a small set of endpoints (see `auth_public/2` in `src/pertisk_eproxy_admin_handler.erl`), including **`GET /`** (in `proxy` mode), **`GET /api/version`**, **`GET /api/auth/config`**, **`POST /api/auth/login`**, **`POST /api/auth/logout`**, **`GET /api/health`**, and **`GET /api/metrics`**.

### Management API

The management API is available at **`http://127.0.0.1:9080/api`** (same host/port as `management_addr` / `management_port` in config).

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/config` | Full proxy config |
| `PUT` | `/api/config` | Replace proxy config |
| `GET` | `/api/sites` | List sites |
| `POST` | `/api/sites` | Add site |
| `DELETE` | `/api/sites/:host` | Remove site |
| `GET` | `/api/health` | Health report |
| `GET` | `/api/metrics` | Prometheus metrics |
| `POST` | `/api/reload` | Hot-reload from file |

Many more routes (sites by host, backends, certificates, DNS providers, `GET /api/management`, `GET /api/stats`, WebSocket `/api/realtime`, etc.) are registered in `build_admin_api_routes/0` in `src/pertisk_eproxy_app.erl` and documented in the module header of `src/pertisk_eproxy_admin_handler.erl`.

### Admin UI (production assets)

The built SPA is shipped under `priv/admin/`. Rebuild after UI changes:

```bash
cd admin && npm ci && npm run build
```

## Further reading

- **`README_SQLITE.md`** — SQLite schema, certificates, DNS providers, and related operational notes.
