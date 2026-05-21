# Pertisk eProxy Helm Chart (Ingress Controller)

Helm chart for [pertisk-eproxy](https://github.com/pertisktech/pertisk-eproxy) in **ingress mode**: watches Kubernetes `Ingress` resources and TLS `Secret`s, hot-reloads routes and certificates (ekub). Management API is read-only.

Mirrors the layout of [pertisk-rproxy `deploy/helm/pertisk-ingress`](https://github.com/pertisktech/pertisk-rproxy/tree/main/deploy/helm/pertisk-ingress).

## Prerequisites

- Kubernetes 1.19+
- Helm 3+
- Controller image built from this repo (`make docker-release` or `make docker-eproxy-multi`)

## Install

```bash
# Build and push both images (Harbor)
make docker-harbor-multi VERSION=0.1.0
#   proxy:   harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy
#   ingress: harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/ingress

# Install ingress controller chart (uses ingress image)
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy \
  -n pertisk-eproxy \
  --create-namespace \
  --set image.tag=0.1.0
```

## Uninstall

```bash
helm uninstall pertisk-eproxy -n pertisk-eproxy
```

## Configuration

| Key | Description | Default |
|-----|-------------|---------|
| `replicaCount` | Replicas (ignored when HPA on) | `3` |
| `autoscaling.enabled` | HPA | `true` |
| `image.registry` | Registry | `harbor.tools.thaidevops.co` |
| `image.repository` | Image path (ingress image) | `pertisksoft/pertisk-eproxy/ingress` |
| `ingress.className` | `ingressClassName` filter | `pertisk-eproxy` |
| `ingress.watchNamespace` | Single namespace (empty = all) | `""` |
| `leaderElection.enabled` | K8s Lease leader election | `true` |
| `service.type` | Service type | `LoadBalancer` |
| `service.http3Port` | UDP port for HTTP/3 (0/null to disable) | `443` |
| `controller.config` | `ingress.json` body | see `values.yaml` |
| `persistence.enabled` | `emptyDir` or PVC for `data/` | `true` |

Environment variables set on the pod match `pertisk_ingress_env` (`PERTISK_K8S_*`, `PERTISK_MODE=ingress`, `PERTISK_CONFIG_FILE`).

## RBAC

ClusterRole grants:

- `ingresses`: get, list, watch
- `secrets`: get, list, watch (TLS)
- `leases`: get, list, watch, create, update, patch

## Example Ingress

```bash
kubectl apply -f examples/k8s-ingress.yaml
```

Ensure `spec.ingressClassName` matches `ingress.className` (default `pertisk-eproxy`).

## Differences from pertisk-rproxy chart

| | rproxy `pertisk-ingress` | eproxy `pertisk-eproxy` |
|--|--------------------------|-------------------------|
| CRDs | Optional PertiskBackend/Ingress | Not included (standard Ingress only) |
| Metrics | Dedicated `:9090` | `GET /api/metrics` on management port |
| Probes | `/live`, `/ready` | `/api/ingress/live`, `/api/ingress/ready` (no auth; also `/api/ingress/status`) |
| Auth secret | `PERTISK_ADMIN` env | Baked `sys.config` / SQLite (ingress API read-only) |
| Listen ports | 8080 / 8443 in container | 80 / 443 (configurable via `controller.config`) |
