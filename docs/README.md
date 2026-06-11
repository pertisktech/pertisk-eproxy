# pertisk-eproxy Documentation

**pertisk-eproxy** is an Erlang/OTP reverse proxy and Kubernetes ingress
controller built on Cowboy. It terminates HTTP/1.1, HTTP/2 (TLS), and optional
HTTP/3 (QUIC), proxies to upstream backends via Gun, and exposes a management
listener (REST API + admin SPA) on port **9080**.

These docs follow the [Diátaxis](https://diataxis.fr/) split:
**tutorials** teach, **how-to guides** solve a specific task,
**concepts** explain how things fit together, **reference** is the exact API.

## Start here

| If you ... | Read |
|---|---|
| Need a one-paragraph pitch | [Overview](overview.md) |
| Want a running proxy in 5 minutes | [Quickstart](quickstart.md) |
| Want to learn eproxy from scratch | [Tutorials](#tutorials) |
| Have a specific task in mind | [How-to guides](#how-to-guides) |
| Want to understand the model | [Concepts](#concepts) |
| Want the exact API | [Reference](#reference) |

## Tutorials

Step-by-step, learning-oriented.

- [Your first reverse proxy](tutorials/your-first-proxy.md)
- [Run the ingress controller locally](tutorials/ingress-controller.md)

## How-to guides

Task-oriented recipes. Each guide is a specific problem and its solution.

**Configuration**

- [Configure sites and backends](guides/configure-sites-backends.md)
- [Hot-reload configuration](guides/hot-reload.md)
- [Set log level and access logging](guides/logging.md)

**TLS and certificates**

- [Import TLS certificates](guides/import-tls-certificates.md)
- [ACME DNS-01 and SQLite storage](README_SQLITE.md)

**Performance**

- [Tune ingress throughput](guides/tune-ingress-throughput.md)
- [Verify HTTP/3 (QUIC)](QUIC.md)

**Operations**

- [Prometheus metrics](guides/prometheus-metrics.md)
- [Deploy with Helm](guides/deploy-with-helm.md)
- [Upgrade RPM packages](RPM_UPGRADE.md)

**Kubernetes**

- [Ingress controller implementation notes](K8S_INGRESS_IMPLEMENTATION.md)

## Concepts

Explanation-oriented. Read these to understand why eproxy is shaped the way it is.

- [Architecture](concepts/architecture.md)
- [Proxy vs ingress mode](concepts/proxy-vs-ingress.md)
- [Request lifecycle](concepts/request-lifecycle.md)
- [Kubernetes reconciliation](concepts/kubernetes-ingress.md)

## Reference

Information-oriented. The exact API for each module is generated from source
by [ex_doc](https://hexdocs.pm/ex_doc); browse the sidebar **Modules** section,
grouped as:

- **Application:** `pertisk_eproxy_app`, `pertisk_eproxy_sup`
- **Proxy core:** `pertisk_eproxy_handler`, `pertisk_eproxy_router`, `pertisk_eproxy_backend`, `pertisk_eproxy_lb`, `pertisk_eproxy_upstream_pool`
- **HTTP/3:** `pertisk_eproxy_h3_api_gateway`, `pertisk_eproxy_h3_local_admin`, `pertisk_eproxy_alt_svc`
- **Admin API:** `pertisk_eproxy_admin_handler`, `pertisk_eproxy_admin_routes`, `pertisk_eproxy_admin_realtime`
- **Ingress controller:** `pertisk_ingress_watcher`, `pertisk_ingress_reconciler`, `pertisk_ingress_leader`
- **Configuration:** `pertisk_eproxy_config`, `pertisk_eproxy_db`
- **Auth:** `pertisk_eproxy_auth`, `pertisk_eproxy_auth0`, `pertisk_eproxy_env_auth`
- **Metrics:** `pertisk_eproxy_metrics`, `pertisk_eproxy_stats`
- **ACME / TLS:** `pertisk_eproxy_acme_client`, `pertisk_eproxy_tls_import`

Build locally: `make docs` then open `doc/index.html`.
