# Quickstart

Run **pertisk-eproxy** in **proxy** mode locally in about five minutes.

## Prerequisites

- Erlang/OTP (see `rebar.config` for versions used in CI)
- `rebar3`

## Build

```bash
make compile
```

## Configure

Edit `config/proxy.json` — minimal example:

```json
{
  "mode": "proxy",
  "http_addr": "0.0.0.0",
  "http_port": 8080,
  "management_addr": "127.0.0.1",
  "management_port": 9080,
  "sites": [],
  "backends": []
}
```

Sites and backends can also be added via the admin UI after start.

## Start

```bash
rebar3 shell
```

Or:

```bash
make run
```

## Verify

Management API (default `127.0.0.1:9080`):

```bash
curl -s http://127.0.0.1:9080/api/version | jq .
curl -s http://127.0.0.1:9080/api/health | jq .
```

Prometheus metrics (default `:9090`):

```bash
curl -s http://127.0.0.1:9090/metrics | head
```

Admin UI: open `http://127.0.0.1:9080/` in a browser.

## Hot reload

After editing `config/proxy.json` on disk:

```bash
curl -X POST http://127.0.0.1:9080/api/reload
```

Or use **Settings → Reload Config** in the admin UI.

## What's next

- Add routes: [Your first reverse proxy](tutorials/your-first-proxy.md)
- Understand modes: [Proxy vs ingress](concepts/proxy-vs-ingress.md)
- Kubernetes: [Run the ingress controller](tutorials/ingress-controller.md)
- Build docs: `make docs` → `doc/index.html`
