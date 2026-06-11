# Your first reverse proxy

Add a site and backend, then proxy HTTP traffic to an upstream.

## 1. Define a backend

In `config/proxy.json` (or via `POST /api/backends`):

```json
{
  "backends": [
    {
      "name": "example-backend",
      "upstreams": [
        {"address": "127.0.0.1:8000", "weight": 1}
      ],
      "algorithm": "round_robin"
    }
  ]
}
```

Start any HTTP server on port 8000 for testing (for example `python3 -m http.server 8000`).

## 2. Define a site

```json
{
  "sites": [
    {
      "host": "example.localhost",
      "backend": "example-backend",
      "routes": [
        {"path": "/", "path_type": "prefix"}
      ]
    }
  ]
}
```

## 3. Reload

```bash
curl -X POST http://127.0.0.1:9080/api/reload
```

## 4. Send traffic

```bash
curl -H "Host: example.localhost" http://127.0.0.1:8080/
```

## 5. Inspect in the admin UI

Open `http://127.0.0.1:9080/`, sign in if `admin_auth` is enabled, and check
**Sites**, **Backends**, and **Logs**.

## What's next

- [Configure sites and backends](../guides/configure-sites-backends.md)
- [Import TLS certificates](../guides/import-tls-certificates.md)
- [SQLite and ACME](../README_SQLITE.md)
