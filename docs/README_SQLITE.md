# Pertisk eProxy — Erlang/Cowboy Reverse Proxy (Proxy-Only Mode)

A lightweight HTTP reverse proxy written in Erlang/OTP using Cowboy. Configuration via JSON file, no admin UI, no Kubernetes integration.

## Quick Start

### 1. Build

```bash
make compile
```

### 2. Configure

Edit [config/proxy.json](config/proxy.json):

```json
{
  "http_addr": "0.0.0.0",
  "http_port": 8080,
  "management_addr": "127.0.0.1",
  "management_port": 9080,
  "sites": [
    {
      "host": "example.localhost",
      "backend": "example-backend",
      "routes": [
        {"path": "/", "path_type": "prefix"}
      ]
    }
  ],
  "backends": [
    {
      "name": "example-backend",
      "algorithm": "round_robin",
      "health_path": "/health",
      "health_interval_secs": 30,
      "upstreams": [
        {"addr": "127.0.0.1:3000", "weight": 1},
        {"addr": "127.0.0.1:3001", "weight": 1}
      ]
    }
  ]
}
```

### 3. Start Proxy

```bash
make run
```

The proxy will listen on:
- **Port 8080**: HTTP reverse proxy
- **Port 9080**: Management API (read-only)

### 4. Test

Route a test request through the proxy:

```bash
# Hit the example.localhost site → routes to 127.0.0.1:3000
curl -H "Host: example.localhost" http://127.0.0.1:8080/

# View current config via API
curl http://127.0.0.1:9080/api/config | python3 -m json.tool

# Check backend health
curl http://127.0.0.1:9080/api/health | python3 -m json.tool

# View Prometheus metrics
curl http://127.0.0.1:9080/api/metrics

# Reload config (after editing config/proxy.json)
curl -X POST http://127.0.0.1:9080/api/reload
```

## Configuration

### File Format

[config/proxy.json](config/proxy.json) defines:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `http_addr` | string | No | Listen address (default: `0.0.0.0`) |
| `http_port` | integer | No | HTTP port (default: `8080`) |
| `https_port` | integer | No | HTTPS port (omit to disable) |
| `management_addr` | string | No | Management API address (default: `127.0.0.1`) |
| `management_port` | integer | No | Management API port (default: `9080`) |
| `tls_cert_file` | string | No | Path to TLS certificate (PEM) |
| `tls_key_file` | string | No | Path to TLS private key (PEM) |
| `sites` | array | Yes | List of site routing rules |
| `backends` | array | Yes | List of backend pools |

### Sites

```json
{
  "host": "api.example.com",
  "backend": "api-backend",
  "routes": [
    {
      "path": "/api",
      "path_type": "prefix",
      "rewrite": "/"
    },
    {
      "path": "/health",
      "path_type": "exact"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `host` | string | Domain name (supports `*.example.com` wildcard) |
| `backend` | string | Backend name (must exist in `backends`) |
| `routes` | array | Path-based routing rules |

### Routes (Path Rewrites)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `path` | string | `/` | Path pattern to match |
| `path_type` | string | `prefix` | `exact` or `prefix` |
| `rewrite` | string | null | Rewrite target (if omitted, original path sent upstream) |

**Example**: Route `/api/v1/users` → upstream gets `/users`:

```json
{
  "path": "/api/v1",
  "path_type": "prefix",
  "rewrite": "/"
}
```

### Backends

```json
{
  "name": "api-backend",
  "algorithm": "round_robin",
  "health_path": "/api/health",
  "health_interval_secs": 30,
  "upstreams": [
    {"addr": "api1.internal:8000", "weight": 2},
    {"addr": "api2.internal:8000", "weight": 1}
  ]
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | Required | Backend identifier |
| `algorithm` | string | `round_robin` | `round_robin`, `least_connections`, `ip_hash` |
| `health_path` | string | null | Health check endpoint (HTTP GET) |
| `health_interval_secs` | integer | `30` | Health check interval (seconds) |
| `upstreams` | array | Required | List of upstream servers |
| `weight` | integer | `1` | Load balancing weight (for round_robin) |

## Management API

All endpoints serve on `127.0.0.1:9080`:

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/config` | Fetch full proxy config |
| `GET` | `/api/sites` | List all sites |
| `GET` | `/api/sites/:host` | Get a specific site |
| `GET` | `/api/backends` | List all backends |
| `GET` | `/api/backends/:name` | Get backend + upstream health |
| `GET` | `/api/health` | Overall proxy health |
| `GET` | `/api/metrics` | Prometheus metrics (text format) |
| `POST` | `/api/reload` | Reload config from JSON file |

## Architecture

### Process Tree

```
pertisk_eproxy_sup (one_for_one)
├── pertisk_eproxy_backend_sup (one_for_one)
│   └── backend_<name> (one per backend, gen_server)
│       ├── Maintains load balancing state
│       ├── Tracks upstream connection counts
│       └── Runs health checks
├── pertisk_eproxy_config (gen_server)
│   ├── Loads config from JSON file
│   ├── Caches in ETS for fast reads
│   └── Syncs backend workers on reload
└── pertisk_eproxy_metrics (gen_server)
    └── Collects + exposes Prometheus metrics
```

### Request Flow

```
Client
  ↓
Cowboy (port 8080)
  ↓
pertisk_eproxy_handler
  ├─ Is WebSocket? → pertisk_eproxy_ws_handler
  ├─ Route via pertisk_eproxy_router
  ├─ Pick upstream via pertisk_eproxy_backend (LB state)
  └─ Forward via Gun (HTTP client)
  ↓
Upstream
```

## Features

✅ **HTTP/HTTPS**: Full HTTP/1.1 + HTTP/2 support (TLS via `tls_cert_file`/`tls_key_file` in `config/proxy.json`)  
✅ **WebSocket**: Transparent WebSocket proxying  
✅ **Health Checks**: Configurable per-backend HTTP health endpoint + interval  
✅ **Load Balancing**: Round-robin, least-connections, IP-hash  
✅ **Path Rewrites**: Prefix stripping, path rewriting per route  
✅ **Metrics**: Prometheus metrics (request count, latency, upstream health)  
✅ **Logging**: Structured logging via Lager (console + file)  
✅ **Connection Pooling**: Gun connection cache per upstream  
✅ **Hot Reload**: Update JSON config + call `/api/reload` (no restart needed)  

❌ **No Admin UI**: Configuration is managed via JSON file + API (read-only)  
❌ **No TLS Certificate Management**: Use Let's Encrypt / cert manager separately  
❌ **No Kubernetes Integration**: Standalone reverse proxy only  
❌ **No SQLite Backend** (yet): Can be added later with pure Erlang SQLite library  

## Development

### Rebuild & Test

```bash
# Compile
make compile

# Run unit tests (if any)
make test

# Static analysis (Dialyzer)
make dialyzer

# Clean build artifacts
make clean
```

### Logs

- **Console**: Real-time INFO logs (configured in [config/sys.config](config/sys.config))
- **Files**:
  - `log/proxy.log` — All proxy operations (INFO level)
  - `log/error.log` — Errors and warnings

### Debug

Start in the Erlang shell with all debug logs:

```bash
erl -config config/sys.config \
    -eval "lager:set_loglevel(lager_console_backend, debug)" \
    -pa _build/default/lib/*/ebin \
    -s pertisk_eproxy_app start
```

## Building a Release

```bash
make release
```

Output: `_build/default/rel/pertisk_eproxy/`

To run the release:

```bash
_build/default/rel/pertisk_eproxy/bin/pertisk_eproxy foreground
```

Or as a daemon (requires systemd or similar):

```bash
_build/default/rel/pertisk_eproxy/bin/pertisk_eproxy start
```

## Performance Tuning

Edit `config/vm.args`:

```
# Number of scheduler threads (auto = cores)
+S auto

# Async thread pool
+A 32

# Process queue length (increase for high-traffic)
+Q 65536

# Max processes
+P 1048576

# Keep alive for idle connections
+K true
```

## License

MIT OR Apache-2.0

## See Also

- **Cowboy**: https://ninenines.eu/docs/en/cowboy/2.12/manual/
- **Gun**: http://ninenines.eu/docs/en/gun/2.1/manual/
- **Lager**: https://github.com/erlang-lager/lager
- **Prometheus**: https://github.com/deadtrickster/prometheus.erl

