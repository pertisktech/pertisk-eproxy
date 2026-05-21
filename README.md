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
- **`ingress`**: Kubernetes ingress controller; sites/backends from cluster `Ingress` + TLS Secrets; management API is read-only.

`mode` is part of the proxy JSON configuration (`proxy`, `proxy_admin`, or `ingress`), or set `PERTISK_MODE=ingress` for the ingress image.

## Docker images (Harbor)

| Mode | Dockerfile | Image |
|------|------------|--------|
| Proxy / admin | `Dockerfile` | `harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy` |
| Ingress controller | `Dockerfile.ingress` | `harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/ingress` |

```bash
make docker-proxy-multi VERSION=0.1.0      # push proxy
make docker-ingress-multi VERSION=0.1.0  # push ingress
make docker-harbor-multi VERSION=0.1.0   # push both
```

Helm chart `deploy/helm/pertisk-eproxy` uses the **ingress** image by default.

## Management listener

Default bind is **`127.0.0.1:9080`** (`management_addr`, `management_port` in config). REST paths use the **`/api/…`** prefix on that listener (e.g. `http://127.0.0.1:9080/api/config`).

### Authentication

- **`admin_auth`** in `config/sys.config`: `disabled` (open API) or `local` (Bearer session after `POST /api/auth/login`).
- When `local` is enabled, most `/api/*` routes require `Authorization: Bearer <token>`.
- Unauthenticated access is still allowed for a small set of endpoints (see `auth_public/2` in `src/pertisk_eproxy_admin_handler.erl`), including **`GET /`** (in `proxy` mode), **`GET /api/version`**, **`GET /api/auth/config`**, **`POST /api/auth/login`**, **`POST /api/auth/logout`**, **`GET /api/health`**, and **`GET /api/metrics`**.

### Hot reload

**`POST /api/reload`** re-reads the proxy JSON from disk (the path in `config/sys.config` key **`config_file`**, default `config/proxy.json`) without restarting the BEAM; existing proxy connections are kept. The same path is exposed at runtime as **`config_file`** on **`GET /api/management`**.

In **`proxy_admin`** mode, the admin **Settings** page runs this reload (**Reload Config**) and shows the **same** route table as below (maintained in `admin/src/managementApiRoutes.ts` — keep it in sync with this section).

### Management API

Base URL follows **`management_addr`** and **`management_port`** (default **`http://127.0.0.1:9080`**). Paths below are rooted on that origin. Path segments **`:host`**, **`:name`**, **`:id`**, and **`:revision`** are route parameters.

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/` | Small JSON `endpoints` catalog (**`mode: proxy`** only; in **`proxy_admin`**, `/` is the web UI) |
| `GET` | `/api/version` | Application version |
| `GET` | `/api/management` | Node, listeners, **`config_file`** (on-disk JSON path), `process_info`, CPU/memory fields, runtime capabilities, optional public IP snapshot |
| `GET` | `/api/stats` | Counters for the admin UI (requests by protocol, bytes, connections, log buffer size, uptime, per-site maps, …) |
| `GET` | `/api/realtime` | **WebSocket** — live snapshots (stats, management, logs, certificates, SSL jobs) |
| `GET` | `/api/logs` | Access log ring; optional query `type`, `host` |
| `GET` | `/api/auth/config` | Auth mode and login-related fields |
| `HEAD` | `/api/auth/config` | Same as `GET` (no JSON body) |
| `POST` | `/api/auth/login` | Obtain session token (`local` auth) |
| `POST` | `/api/auth/refresh` | Refresh session token |
| `GET` | `/api/auth/check` | Whether the current session is authenticated |
| `POST` | `/api/auth/logout` | End session |
| `POST` | `/api/admin/change-password` | Password change (not implemented; returns 501) |
| `GET` | `/api/admin/api-token` | API token status (stub) |
| `POST` | `/api/admin/api-token` | API token (stub) |
| `GET` | `/api/backup/export` | Download config backup |
| `POST` | `/api/backup/restore` | Upload and restore config from backup |
| `GET` | `/api/helm/history` | Helm history (stub for non-K8s deployments) |
| `GET` | `/api/helm/values/:revision` | Helm values for revision (stub) |
| `GET` | `/api/certificates` | List stored TLS certificates |
| `POST` | `/api/certificates` | Create certificate metadata row |
| `POST` | `/api/certificates/import` | Import PEM bundle (new or update) |
| `PUT` | `/api/certificates/:id/import` | Import PEM for existing certificate id |
| `PUT` | `/api/certificates/:id` | Update certificate row |
| `DELETE` | `/api/certificates/:id` | Delete certificate row |
| `GET` | `/api/dns-providers` | List DNS providers (e.g. ACME DNS-01) |
| `POST` | `/api/dns-providers` | Create DNS provider |
| `PUT` | `/api/dns-providers/:id` | Update DNS provider |
| `DELETE` | `/api/dns-providers/:id` | Delete DNS provider |
| `POST` | `/api/tls/listener` | Set `tls_cert_file` / `tls_key_file` on in-memory config (see response notice for HTTPS reload) |
| `GET` | `/api/config` | Full proxy configuration JSON |
| `PUT` | `/api/config` | Replace full configuration (hot reload) |
| `GET` | `/api/sites` | List sites |
| `POST` | `/api/sites` | Add site |
| `GET` | `/api/sites/:host` | Get one site by hostname |
| `PUT` | `/api/sites/:host` | Replace site |
| `DELETE` | `/api/sites/:host` | Remove site |
| `GET` | `/api/backends` | List backends |
| `POST` | `/api/backends` | Add backend |
| `GET` | `/api/backends/:name` | Backend definition and live upstream health |
| `DELETE` | `/api/backends/:name` | Remove backend |
| `GET` | `/api/health` | Aggregated health |
| `GET` | `/api/metrics` | **Prometheus** metrics (text exposition) |
| `POST` | `/api/reload` | Reload configuration from the on-disk config file |

Handlers live in `src/pertisk_eproxy_app.erl` (`build_admin_api_routes/0`), `src/pertisk_eproxy_admin_handler.erl`, and `src/pertisk_eproxy_admin_ws_handler.erl`. Which routes allow unauthenticated access is defined by `auth_public/2` in `pertisk_eproxy_admin_handler.erl`.

### Admin UI (production assets)

The built SPA is shipped under `priv/admin/`. Rebuild after UI changes:

```bash
cd admin && npm ci && npm run build
```

## Further reading

- **`README_SQLITE.md`** — SQLite schema, certificates, DNS providers, and related operational notes.

## HTTP/3 transport verification

Use the helper script to print negotiated QUIC transport parameters from both public DNS and forced-localhost paths.

```bash
chmod +x scripts/verify_h3_params.sh
scripts/verify_h3_params.sh eproxy.arm.thaidevops.co /
```

The script checks ports `443` and `444` and reports lines such as `remote transport[...]` and `peer idle timeout is ...`.

It also prints a PASS/FAIL summary and returns non-zero if required checks fail:

- Required: `public-dns:443`, `localhost-resolve:443`, `localhost-resolve:444`
- Optional: `public-dns:444` (often closed on public edge by design)

In addition, it verifies reverse-proxy protocol behavior on localhost mapping:

- Required HTTP/3 routes: `/`, `/login`, `/api/auth/config`, `/api/version`, `/api/health`
- Required WebSocket handshake over HTTP/1.1: `/api/realtime` returns `101 Switching Protocols`
