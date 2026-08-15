# pertisk-eproxy

Erlang/OTP reverse proxy built on **Cowboy**, with an optional **management listener** (REST + Web UI), **Prometheus** metrics, **HTTP/2** on TLS, and optional **HTTP/3** paths (H3 API gateway / QUIC where enabled in the build).

## Requirements

- Erlang/OTP (see `rebar.config` for typical versions used in CI)
- `rebar3`
- Optional: Node.js 20+ to rebuild the admin UI (`admin/` → `priv/admin/`)

## Repository layout

| Path | Purpose |
|------|---------|
| `src/` | Erlang application |
| `config/` | Runtime JSON (`proxy.json`, `ingress.json`) and `sys.config` |
| `docker/` | Dockerfiles (`Dockerfile.proxy`, `Dockerfile.ingress`) |
| `build/` | Package and image build wrappers (`deploy-deb.sh`, `docker-harbor.sh`) |
| `deploy/` | Helm chart and cluster deploy scripts (`erlang.sh`, `h255.sh`, …) |
| `scripts/` | Release helpers (patches, verify, deb/rpm internals) |

Standard layout: `docker/`, `build/`, `deploy/helm/…`.

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

## High-performance worker tuning

For Erlang/Cowboy, the closest equivalent to NGINX `worker_processes` and `worker_connections` is:

- BEAM schedulers (CPU workers): configured via `config/vm.args` / Helm `beam.erlFlags`
- Cowboy acceptors (listener workers): `*_num_acceptors` in proxy JSON
- Listener connection limits: `proxy_max_connections` and `management_max_connections`

**HTTP/3 k6** — default edge is erlang_quic gateway:

- `quic_enabled: true`, `h3_api_gateway_enabled: true` in `config/proxy.json` / Helm
- A-B Cowboy+quicer: `h3_api_gateway_enabled: false` (slower on 1-vCPU health benches)
- RPM can still ship MsQuic via `scripts/bundle-msquic-for-rpm.sh` for A-B

Recommended production setup:

- Keep `config/vm.args` / `beam.erlFlags` **without** `+S` so BEAM uses all CPUs visible to the container/host. Do not pin `+S 2:2` unless the pod is limited to 2 CPU.
- Let acceptors auto-scale by omitting these keys from JSON (or set them for benches):
	- `http_num_acceptors`
	- `https_num_acceptors`
	- `quic_num_acceptors`
	- `management_num_acceptors`
- Keep `proxy_max_connections` sized to your `ulimit -n` and kernel socket limits.

Current auto behavior in this app:

- Proxy listeners (`http`/`https`/`quic`): scheduler-based default when `*_num_acceptors` is not set.
- Management listener: scheduler-based default when `management_num_acceptors` is not set.

This gives an "auto workers" model similar to NGINX tuning, while still allowing explicit per-listener overrides when required.

See [Tune ingress throughput](docs/guides/tune-ingress-throughput.md).

### HTTP/3 performance

Defaults in `config/proxy.json` / `config/ingress.json`:

| Key | Default |
|-----|---------|
| `h3_max_streams` | 2048 |
| `h3_stream_receive_window` | 8388608 (8 MiB) |
| `h3_conn_receive_window` | 67108864 (64 MiB) |
| `upstream_pool_size` | 256 |
| `upstream_pool_idle_timeout_secs` | 90 |
| `upstream_loopback_pool_enabled` | false |

The H3 gateway uses the same upstream Gun options as TCP HTTPS (`[http2, http]` on TLS) so many concurrent requests can share one upstream HTTP/2 connection. Previously H3 forced `[http]` (one request per connection), which capped throughput around ~120 TPS at 100 VUs.

For local benchmark topologies where upstreams are loopback targets (`127.0.0.1`, `localhost`, `::1`), set `upstream_loopback_pool_enabled: true` to reuse upstream keep-alive sockets. The default keeps loopback requests ephemeral for operational safety.

### Ingress throughput tuning

| Area | Default / behavior | Tuning |
|------|-------------------|--------|
| Runtime | BEAM schedulers from cgroup CPUs (`vm.args` `+A 32`) | Give pods enough CPU; avoid `log_level: debug` |
| Per-request access log | `proxy_access_log: false` (ingress default) | **Biggest win** — skips ring buffer + Lager JSON on 2xx/3xx |
| Health probe logging | `health_access_log: false` | Keep off under k6 / many replicas |
| Upstream pool | `upstream_pool_size: 256`, idle 90s | Size to backend count and concurrency |
| HTTP/3 QUIC | 2048 streams, 8/64 MiB windows | `h3_max_streams`, `h3_*_receive_window` |
| Metrics | `:9090` counters | Use Prometheus, not access logs, for TPS |
| LB pick | `gen_server:call` per backend | Minor at typical ingress scale |

**Recommended ingress Helm overlay** (after defaults in `values.yaml`):

```yaml
controller:
  config:
    proxy_access_log: false
    health_access_log: false
    log_level: warn
    upstream_pool_size: 256
    h3_max_streams: 2048
replicaCount: 1          # or service.externalTrafficPolicy: Local for HTTP/3
resources:
  limits:
    cpu: 2000m
```

Env override: `PERTISK_PROXY_ACCESS_LOG=false`.

### Log level

Application logs (stderr JSON and `log/proxy.log`) use Lager. Set verbosity in the JSON config file or via env.

| Key / env | Default | Effect |
|-----------|---------|--------|
| `log_level` | `info` | `debug`, `info`, `warn` (`warning` accepted), `error` |
| `PERTISK_LOG_LEVEL` | — | Overrides JSON (both proxy and ingress modes) |

Applied on startup and when config is reloaded (`POST /api/reload` in proxy mode, or pod restart after Helm `controller.config` change in ingress mode).

**Helm (ingress):** `controller.config.log_level` in `values.yaml`, or `logging.level` to set `PERTISK_LOG_LEVEL` on the pod.

**Local proxy:** `log_level` in `config/proxy.json`.

### Health probe logging

`GET /api/health` (and `/health`, `/healthz`, `/readyz`) with status **200** is **not** written to access logs or `log/proxy.log` by default — at k6 rates (~4000+ TPS) logging every line would dominate CPU.

| Key | Default | Effect |
|-----|---------|--------|
| `health_access_log` | `false` | Log every successful health request |
| `health_access_log_sample` | `0` | Log 1/N health requests (e.g. `1000` ≈ few lines/sec at 4632 TPS) |

Prometheus metrics (`inc_request`) still count health traffic when logging is off.

### Proxy access logging

Every proxied request normally writes to the admin ring buffer and Lager JSON (`log/proxy.log` + stderr). At ingress scale this dominates CPU when enabled.

| Key / env | Default (ingress) | Effect |
|-----------|-------------------|--------|
| `proxy_access_log` | `false` in `ingress.json` / Helm | Skip 2xx/3xx access logs; **4xx/5xx still logged** |
| `PERTISK_PROXY_ACCESS_LOG` | — | Overrides JSON (`true` / `false`) |

Prometheus `pertisk_eproxy_requests_total` still records all traffic when access logging is off.

### Prometheus metrics server

A dedicated listener exposes Prometheus text at **`GET /metrics`** (default port **9090**), separate from the management API on `:9080`, keeping scrape traffic off the admin listener.

| Key / env | Default | Effect |
|-----------|---------|--------|
| `metrics_port` | `9090` | Prometheus listen port |
| `metrics_addr` | `0.0.0.0` | Bind address |
| `metrics_enabled` | `true` | Set `false` or `PERTISK_METRICS_ENABLED=false` to disable |
| `PERTISK_METRICS_ADDR` | — | Overrides JSON, e.g. `0.0.0.0:9090` |

Legacy **`GET /api/metrics`** on the management port still works for backward compatibility. Prefer `:9090/metrics` for Prometheus Operator / ServiceMonitor scrapes.

**Helm:** `metrics.enabled`, `metrics.addr`, `service.metricsPort`, and `metrics.serviceMonitor` (scrapes `port: metrics`, `path: /metrics`).

**Ingress mode (Helm):** set keys under `controller.config` in `values.yaml` (rendered to `/opt/pertisk_eproxy/config/ingress.json`). After `helm upgrade`, pods reload config on restart. View lines in the admin UI **Logs** tab or `kubectl logs` (JSON to stdout / `log/proxy.log` in the pod).

**Local / dev:** edit `config/ingress.json` when `mode` is `ingress`.

Application config defaults live in `config/sys.config` (e.g. `admin_auth`, ACME-related keys). Proxy routing, sites, backends, and listener ports are loaded from the JSON file pointed to by `config_file` (default `config/proxy.json`). See `README_SQLITE.md` for database-backed certificate and DNS provider storage.

## Modes

- **`proxy`**: management port serves the **React admin UI** at `/` and JSON under `/api/…`.
- **`ingress`**: Kubernetes ingress controller; sites/backends from cluster `Ingress` + TLS Secrets; management API is read-only.

`mode` is part of the proxy JSON configuration (`proxy` or `ingress`), or set `PERTISK_MODE=ingress` for the ingress image. Legacy `proxy_admin` is still accepted as an alias for `proxy` when reading older config.

## Docker images (Harbor)

| Mode | Dockerfile | Image |
|------|------------|--------|
| Proxy / admin | `docker/Dockerfile.proxy` | `harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy` |
| Ingress controller | `docker/Dockerfile.ingress` | `harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/ingress` |

```bash
make docker-proxy-multi VERSION=0.1.0      # push proxy
make docker-ingress-multi VERSION=0.1.0    # push ingress
make docker-harbor-multi VERSION=0.1.0     # push both
./build/docker-harbor.sh 0.1.0             # same as docker-harbor-multi
```

Helm chart `deploy/helm/pertisk-eproxy` uses the **ingress** image by default. Cluster deploy wrappers: `deploy/erlang.sh`, `deploy/h255.sh`, etc. — see [`deploy/README.md`](deploy/README.md).

## Management listener

Default bind is **`127.0.0.1:9080`** (`management_addr`, `management_port` in config). REST paths use the **`/api/…`** prefix on that listener (e.g. `http://127.0.0.1:9080/api/config`).

### Authentication

- **`admin_auth`** in `config/sys.config`: `disabled` (open API) or `local` (Bearer session after `POST /api/auth/login`).
- When `local` is enabled, most `/api/*` routes require `Authorization: Bearer <token>`.
- Unauthenticated access is still allowed for a small set of endpoints (see `auth_public/2` in `src/pertisk_eproxy_admin_handler.erl`), including **`GET /api/version`**, **`GET /api/auth/config`**, **`POST /api/auth/login`**, **`POST /api/auth/logout`**, **`GET /api/health`**, and **`GET /api/metrics`**.

### Hot reload

**`POST /api/reload`** re-reads the proxy JSON from disk (the path in `config/sys.config` key **`config_file`**, default `config/proxy.json`) without restarting the BEAM; existing proxy connections are kept. The same path is exposed at runtime as **`config_file`** on **`GET /api/management`**.

In **`proxy`** mode, the admin **Settings** page runs this reload (**Reload Config**). The route table and generated Swagger/OpenAPI JSON are in the admin **Docs** menu (source: `admin/src/managementApiRoutes.ts`) with an interactive Swagger UI view.

Native Cowboy Swagger UI is also served at **`/api-docs`** on the management listener (for example `http://127.0.0.1:9080/api-docs`).

### Management API

Base URL follows **`management_addr`** and **`management_port`** (default **`http://127.0.0.1:9080`**). Paths below are rooted on that origin. Path segments **`:host`**, **`:name`**, **`:id`**, and **`:revision`** are route parameters.

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/version` | Application version |
| `GET` | `/api/proto` | Protocol/debug snapshot (request scheme/protocol details and headers) |
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
| `POST` | `/api/dns-providers/validate` | Validate DNS provider credentials/configuration |
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
| `GET` | `/api/metrics` | **Prometheus** metrics on management port (legacy; prefer `:9090/metrics`) |
| `POST` | `/api/reload` | Reload configuration from the on-disk config file |
| `GET` | `/api/ingress/live` | Ingress liveness probe |
| `HEAD` | `/api/ingress/live` | Same as `GET` (no JSON body) |
| `GET` | `/api/ingress/ready` | Ingress readiness probe |
| `HEAD` | `/api/ingress/ready` | Same as `GET` (no JSON body) |
| `GET` | `/api/ingress/status` | Ingress controller status snapshot |
| `HEAD` | `/api/ingress/status` | Same as `GET` (no JSON body) |
| `GET` | `/api/ingress/watchers` | Watcher and leader state |
| `GET` | `/api/ingress/errors` | Last ingress reconciliation error |
| `GET` | `/api/ingress/resources` | Effective sites/backends synthesized by ingress reconciliation |
| `GET` | `/api/kubernetes/namespaces` | List Kubernetes namespaces |
| `GET` | `/api/kubernetes/pods` | List Kubernetes pods (optional query `namespace`) |
| `GET` | `/api/kubernetes/services` | List Kubernetes services (optional query `namespace`) |
| `GET` | `/api/kubernetes/tls-secrets` | List Kubernetes TLS secrets (optional query `namespace`) |
| `GET` | `/api/kubernetes/ingresses` | List Kubernetes ingress resources |
| `POST` | `/api/kubernetes/ingresses` | Create Kubernetes ingress resource |
| `GET` | `/api/kubernetes/ingresses/:namespace/:name` | Get one Kubernetes ingress resource |
| `PUT` | `/api/kubernetes/ingresses/:namespace/:name` | Update one Kubernetes ingress resource |
| `DELETE` | `/api/kubernetes/ingresses/:namespace/:name` | Delete one Kubernetes ingress resource |

Ingress admin payloads support `service_namespace` independent of `ingress_namespace`. In ingress mode the controller writes/reads this as annotation `pertisk.tech/backend-namespace` and resolves backend upstreams against that namespace.

For multi-route ingresses that target services in different namespaces, each route may provide its own `service_namespace`; ingress mode stores this as annotation `pertisk.tech/backend-namespaces` (JSON map: service name -> namespace).

Handlers live in `src/pertisk_eproxy_app.erl` (`build_admin_api_routes/0`), `src/pertisk_eproxy_admin_handler.erl`, and `src/pertisk_eproxy_admin_ws_handler.erl`. Which routes allow unauthenticated access is defined by `auth_public/2` in `pertisk_eproxy_admin_handler.erl`.

### Admin UI (production assets)

The built SPA is shipped under `priv/admin/`. Rebuild after UI changes:

```bash
cd admin && npm ci && npm run build
```

## Documentation

Guides and API reference (ExDoc, [Diátaxis](https://diataxis.fr/) layout — same style as [Livery](https://benoitc.github.io/livery/api/readme.html)):

```bash
make docs
open doc/index.html
```

Markdown sources live in `docs/`. Published site: `https://pertisktech.github.io/pertisk-eproxy/` (when GitHub Pages is enabled).

## Further reading

- **`README_SQLITE.md`** — SQLite schema, certificates, DNS providers, and related operational notes.

## HTTP/3 transport verification

Use the helper script to print negotiated QUIC transport parameters from both public DNS and forced-localhost paths.

```bash
chmod +x scripts/verify_h3_params.sh
scripts/verify_h3_params.sh eproxy.example.com /
```

The script checks ports `443` and `444` and reports lines such as `remote transport[...]` and `peer idle timeout is ...`.

It also prints a PASS/FAIL summary and returns non-zero if required checks fail:

- Required: `public-dns:443`, `localhost-resolve:443`, `localhost-resolve:444`
- Optional: `public-dns:444` (often closed on public edge by design)

In addition, it verifies reverse-proxy protocol behavior on localhost mapping:

- Required HTTP/3 routes: `/`, `/login`, `/api/auth/config`, `/api/version`, `/api/health`
- Required WebSocket handshake over HTTP/1.1: `/api/realtime` returns `101 Switching Protocols`

## benchmakr
```sh
CONN=32 STREAMS=8 DUR=10 bash bench/compare.sh
```