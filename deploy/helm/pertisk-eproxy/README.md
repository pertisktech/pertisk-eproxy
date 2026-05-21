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
| `persistence.enabled` | `emptyDir` or PVC for `data/` (K8s TLS PEM cache) | `true` |

### Config sources (proxy vs ingress)

| Mode | Sites / backends | Listener ports / H3 flags | Admin login (local) |
|------|------------------|---------------------------|---------------------|
| **proxy** / **proxy_admin** | SQLite `data/proxy.db` | SQLite + `config/proxy.json` seed | SQLite `admin_users` |
| **ingress** | Kubernetes `Ingress` + TLS `Secret` manifests | `controller.config` / `ingress.json` only | Auth0 SSO or read-only viewer (no SQLite) |

Environment variables on the pod: `PERTISK_MODE=ingress`, `PERTISK_CONFIG_FILE`, `PERTISK_K8S_*` (see `pertisk_ingress_env`).

### Ports (same idea as pertisk-rproxy)

| Where | HTTP | HTTPS | HTTP/3 | Management |
|-------|------|-------|--------|------------|
| **Service** (LB) | 80 | 443 | 443/udp | 9080 |
| **Container** | 8080 | 8443 | 8443/udp | 9080 |

`EXPOSE` in the Docker image is documentation only; Kubernetes uses Service `targetPort` → named container ports. You do **not** need to publish 80/443 inside the container.

### Troubleshooting pod logs

| Log | Cause | Fix |
|-----|--------|-----|
| `ekub init failed: {options,{server_name_indication,undefined}}` | Old ekub SSL patch | Rebuild ingress image (current patch removes invalid SNI) |
| `fail_if_no_peer_cert` | Old image | Rebuild with `scripts/patch-ekub.sh` in Docker build |
| `incompatible quic_qpack` | Image built without `_checkouts/quic` | Rebuild; build fails at `verify-deps` if quic patch missing |

```bash
make docker-ingress-multi VERSION=<tag>
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy -n pertisk-eproxy --set image.tag=<tag>
kubectl rollout restart deployment -n pertisk-eproxy
```

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
| Auth secret | `PERTISK_ADMIN` env | Auth0 / read-only viewer (no SQLite in ingress mode) |
| Listen ports | 8080 / 8443 in container | 80 / 443 (configurable via `controller.config`) |
