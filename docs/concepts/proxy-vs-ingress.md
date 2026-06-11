# Proxy vs ingress mode

pertisk-eproxy runs as one application with two deployment personalities.

## Proxy mode

- **Config source:** SQLite `data/proxy.db` (seeded from `config/proxy.json` on first deploy)
- **Admin API:** full read/write (sites, backends, certificates, DNS providers)
- **Image:** `pertisk-eproxy/proxy`
- **Use when:** standalone reverse proxy, homelab, or VM with local config

Set `"mode": "proxy"` in `config/proxy.json`.

## Ingress mode

- **Config source:** Kubernetes `Ingress` resources + TLS `Secret`s (watched via ekub)
- **Listener settings:** `config/ingress.json` or Helm `controller.config`
- **Admin API:** read-only view of reconciled routes; cluster dashboard APIs
- **Image:** `pertisk-eproxy/ingress`
- **Use when:** Kubernetes ingress controller with `ingressClassName: pertisk-eproxy`

Set `"mode": "ingress"` or `PERTISK_MODE=ingress`.

## Shared runtime

Both modes share:

- Cowboy proxy listeners and HTTP/3 gateway
- Gun upstream pool and load balancing
- Prometheus metrics on `:9090`
- Management UI on `:9080` (auth via SQLite in proxy mode, env/Auth0 in ingress)

## Switching

Modes are not hot-swapped at runtime — use the correct image and config file for
the deployment target.
