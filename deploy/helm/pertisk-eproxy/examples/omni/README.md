# Talos Omni behind pertisk-eproxy

Matches [Sidero Labs nginx layout](https://docs.siderolabs.com/omni/self-hosted/expose-omni-with-nginx-https): three public hostnames, Omni on localhost.

| Host | Omni port | Traffic |
|------|-----------|---------|
| `omni.example.com` | `8080` | UI + gRPC/HTTP API |
| `api.omni.example.com` | `8090` | SideroLink (gRPC) |
| `kube.omni.example.com` | `8100` | Kubernetes proxy (HTTP/WebSocket) |

Omni container (same host as the proxy):

```bash
--bind-addr=127.0.0.1:8080
--advertised-api-url=https://omni.example.com/
--siderolink-api-bind-addr=127.0.0.1:8090
--siderolink-api-advertised-url=https://api.omni.example.com:443
--k8s-proxy-bind-addr=127.0.0.1:8100
--advertised-kubernetes-proxy-url=https://kube.omni.example.com/
```

Replace `omni.example.com` with your domain (e.g. `omni.pertisk.com`).

## Proxy mode (SQLite + admin API)

**Critical:** set `advertise_http3: false` on all three Omni sites. Omni uses long-lived gRPC streams; HTTP/3 causes 421 redirects and broken watches.

### First deploy

Merge `proxy-omni-seed.json` into `config/proxy.json` (sites + backends only) before the first start, or copy values into the admin UI.

Suggested listener timeouts in `config/proxy.json`:

```json
"upstream_request_timeout_ms": 3600000,
"upstream_stream_request_timeout_ms": 3600000,
"downstream_idle_timeout_ms": 3600000
```

(Nginx uses 1h; Omni exec/attach sessions can be idle a long time.)

### Existing deployment (admin API)

```bash
MGMT=http://127.0.0.1:9080

# Backends
curl -sS -X POST "$MGMT/api/backends" -H 'Content-Type: application/json' -d '{
  "name": "omni-ui",
  "upstreams": [{"addr": "127.0.0.1:8080", "weight": 1}],
  "algorithm": "round_robin"
}'
curl -sS -X POST "$MGMT/api/backends" -H 'Content-Type: application/json' -d '{
  "name": "omni-siderolink",
  "grpc_upstream": true,
  "upstreams": [{"addr": "127.0.0.1:8090", "weight": 1}],
  "algorithm": "round_robin"
}'
curl -sS -X POST "$MGMT/api/backends" -H 'Content-Type: application/json' -d '{
  "name": "omni-kube",
  "upstreams": [{"addr": "127.0.0.1:8100", "weight": 1}],
  "algorithm": "round_robin"
}'

# Sites (advertise_http3 false on each)
curl -sS -X POST "$MGMT/api/sites" -H 'Content-Type: application/json' -d '{
  "host": "omni.pertisk.com",
  "backend": "omni-ui",
  "advertise_http3": false,
  "routes": [{"path": "/", "path_type": "prefix"}]
}'
curl -sS -X POST "$MGMT/api/sites" -H 'Content-Type: application/json' -d '{
  "host": "api.omni.pertisk.com",
  "backend": "omni-siderolink",
  "advertise_http3": false,
  "routes": [{"path": "/", "path_type": "prefix"}]
}'
curl -sS -X POST "$MGMT/api/sites" -H 'Content-Type: application/json' -d '{
  "host": "kube.omni.pertisk.com",
  "backend": "omni-kube",
  "advertise_http3": false,
  "routes": [{"path": "/", "path_type": "prefix"}]
}'
```

Add TLS certificates per host via admin UI or ACME, then point DNS A records at the proxy machine.

### Update existing Omni site

If `omni.pertisk.com` already exists, disable HTTP/3:

```bash
curl -sS -X PUT "http://127.0.0.1:9080/api/sites/omni.pertisk.com" \
  -H 'Content-Type: application/json' \
  -d '{"host":"omni.pertisk.com","backend":"<your-backend>","advertise_http3":false,"routes":[{"path":"/","path_type":"prefix"}]}'
```

## Ingress mode

See `ingress-omni.yaml` and annotations:

- `pertisk.io/grpc-mixed: "true"` — main UI host
- `pertisk.io/grpc-upstream: "true"` — `api.*` SideroLink host
- `pertisk.io/advertise-http3: "false"` — `kube.*` host

## Verify

After deploy with the Omni code fixes:

1. No repeated `421` on `ResourceService/Watch` in access logs.
2. Omni UI loads over HTTPS.
3. Machines register on `api.*`.
4. `kubectl` via `kube.*` works.

### Probe `api.*` correctly (gRPC)

`api.omni.*` is a gRPC endpoint. Plain browser checks (`GET /` or `HEAD /`) can
return `502` while gRPC traffic is actually healthy.

Use an HTTP/2 gRPC-style probe instead:

```bash
curl -sk --http2 -D - -o /dev/null \
  -H 'content-type: application/grpc' \
  -H 'te: trailers' \
  --data-binary '' \
  https://api.omni.example.com/
```

Expected healthy signal: HTTP/2 response with `content-type: application/grpc`
and a gRPC status/message (for `/` you may get `grpc-status: 12`, which still
proves the gRPC path is reachable through the proxy).
