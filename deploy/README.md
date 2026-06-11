# Deploy

Helm chart: [`helm/pertisk-eproxy`](helm/pertisk-eproxy/).

Environment-specific wrappers build the ingress image and run `helm upgrade --install`:

| Script | Default admin host | Notes |
|--------|-------------------|--------|
| `erlang.sh` | `admin.erlang.thaidevops.co` | Primary dev/test cluster |
| `cloud.sh` | `admin.cloud.thaidevops.co` | Floating IP annotations |
| `hz.sh` | `admin.cloud.thaidevops.co` | Hetzner cloud (same as cloud) |
| `h255.sh` | `admin.talos.pertisk.com` | Talos h255 |
| `arm.sh` | `admin.arm.thaidevops.co` | ARM cluster |

```bash
VERSION=0.5.10 ./deploy/erlang.sh
ADMIN_HOST=admin.example.com ./deploy/h255.sh
```

Override via env: `VERSION`, `NAMESPACE`, `RELEASE_NAME`, `CHART_PATH`, `ADMIN_HOST`, `HELM_TIMEOUT`.

Examples (cert-manager, sample Ingress): `helm/pertisk-eproxy/examples/`.
