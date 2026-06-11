# Configure sites and backends

Sites map hostnames and paths to named backends. Backends define upstream targets
and load-balancing.

## JSON file (proxy mode)

Edit `config/proxy.json`, then reload:

```bash
curl -X POST http://127.0.0.1:9080/api/reload
```

## REST API

```bash
# List
curl -s http://127.0.0.1:9080/api/sites | jq .
curl -s http://127.0.0.1:9080/api/backends | jq .

# Add backend
curl -X POST http://127.0.0.1:9080/api/backends \
  -H 'Content-Type: application/json' \
  -d '{"name":"api","upstreams":[{"address":"10.0.0.5:8080","weight":1}],"algorithm":"round_robin"}'
```

In **proxy** mode, changes persist to SQLite. In **ingress** mode, sites/backends
come from Kubernetes and the API is read-only.

## Route types

| `path_type` | Matches |
|-------------|---------|
| `prefix` | Path prefix |
| `exact` | Exact path |

## See also

- [Your first reverse proxy](../tutorials/your-first-proxy.md)
- [README_SQLITE.md](../README_SQLITE.md)
