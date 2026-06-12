# Deploy with Helm

Install the ingress controller chart from this repository.

## Build image

```bash
make docker-ingress-multi VERSION=0.1.0
```

## Install

```bash
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy \
  -n pertisk-eproxy \
  --create-namespace \
  --set image.tag=0.1.0
```

## Value profiles

| File | Purpose |
|------|---------|
| `values.yaml` | Default (dev-friendly; weak password allowed) |
| `values-production.yaml` | Strong password required, PDB, ServiceMonitor, Local LB policy |
| `values-h3-single.yaml` | Single replica + Local policy for reliable HTTP/3 |

Production example:

```bash
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy \
  -f deploy/helm/pertisk-eproxy/values-production.yaml \
  --set auth.password="$(openssl rand -base64 24)" \
  -n pertisk-eproxy --create-namespace
```

See [ROADMAP_PHASES.md](../ROADMAP_PHASES.md) for what each phase adds.

## Cluster scripts

| Script | Default admin host |
|--------|-------------------|
| `deploy/erlang.sh` | `admin.erlang.thaidevops.co` |
| `deploy/h255.sh` | `admin.talos.pertisk.com` |
| `deploy/arm.sh` | `admin.arm.thaidevops.co` |

```bash
VERSION=0.5.10 ./deploy/erlang.sh
```

## Chart docs

See `deploy/helm/pertisk-eproxy/README.md` and `deploy/README.md`.

## Examples

`deploy/helm/pertisk-eproxy/examples/` — admin Ingress, app Ingress, cert-manager.
