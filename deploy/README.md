# Deploy

Helm chart: [`helm/pertisk-eproxy`](helm/pertisk-eproxy/).

Environment-specific wrappers build the ingress image and run `helm upgrade --install`:

| Script | Default admin host | Notes |
|--------|-------------------|--------|
| `erlang.sh` | `admin.erlang.pertisk.com` | General Erlang cluster deploy |
| `h255.sh` | `admin.erlang.pertisk.com` | **talos-255-prod** — HTTP/3 + Gateway API |
| `cloud.sh` | `admin.cloud.thaidevops.co` | Floating IP annotations |
| `hz.sh` | `admin.cloud.thaidevops.co` | Hetzner cloud (same as cloud) |
| `orion.sh` | `admin.orion.pertisk.com` | Orion cluster |
| `arm.sh` | `admin.arm.thaidevops.co` | ARM cluster |

```bash
export KUBECONFIG=/path/to/kubeconfig
VERSION=0.5.98 ./deploy/h255.sh

# Gateway API admin (no Ingress for admin):
ADMIN_VIA_GATEWAY=true VERSION=0.5.98 ./deploy/h255.sh
```

**Split with pertisk-rproxy (Rust):** eproxy → `admin.erlang.pertisk.com`; rproxy → `admin.gateway.pertisk.com`. See [`gateway-api/README.md`](gateway-api/README.md).

Override via env: `VERSION`, `NAMESPACE`, `RELEASE_NAME`, `CHART_PATH`, `ADMIN_HOST`, `HELM_TIMEOUT`.

Examples (cert-manager, sample Ingress): `helm/pertisk-eproxy/examples/`.
