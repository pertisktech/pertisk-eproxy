# Pertisk eProxy Helm Chart (Ingress Controller)

Helm chart for [pertisk-eproxy](https://github.com/pertisktech/pertisk-eproxy) in **ingress mode**: watches Kubernetes `Ingress` resources and TLS `Secret`s, hot-reloads routes and certificates (ekub). Management API is read-only.

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
| `ingress.gatewayApiEnabled` | Reconcile Gateway API HTTPRoutes; creates `GatewayClass` | `false` |
| `ingress.watchNamespace` | Single namespace (empty = all) | `""` |
| `leaderElection.enabled` | K8s Lease leader election | `true` |
| `helm.enabled` | Enable Helm history/values API in ingress admin | `true` |
| `helm.namespace` | Helm release namespace override (empty uses release namespace) | `""` |
| `helm.historyMax` | Max Helm revisions returned by history API | `20` |
| `service.type` | Service type | `LoadBalancer` |
| `service.http3Port` | UDP port for HTTP/3 (0/null to disable) | `443` |
| `controller.config` | `ingress.json` body | see `values.yaml` |
| `controller.config.log_level` | Lager verbosity (`debug`, `info`, `warn`, `error`) | `info` |
| `logging.level` | Sets `PERTISK_LOG_LEVEL` env (overrides JSON) | `""` (use JSON only) |
| `persistence.enabled` | `emptyDir` or PVC for `data/` (K8s TLS PEM cache) | `true` |

### Config sources (proxy vs ingress)

| Mode | Sites / backends | Listener ports / H3 flags | Admin login (local) |
|------|------------------|---------------------------|---------------------|
| **proxy** | SQLite `data/proxy.db` | SQLite + `config/proxy.json` seed | SQLite `admin_users` |
| **ingress** | Kubernetes `Ingress` + TLS `Secret` manifests | `controller.config` / `ingress.json` only | Auth0 SSO or read-only viewer (no SQLite) |

Environment variables on the pod: `PERTISK_MODE=ingress`, `PERTISK_CONFIG_FILE`, `PERTISK_K8S_*`, `PERTISK_HELM_*` (see `pertisk_ingress_env`).

### Ports

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
| `incompatible quic_qpack` | Image built without patched quic | Rebuild; Docker fails at `verify-release-quic` if QPACK wrong |
| `ekub init failed: nxdomain` | Default API host `kubernetes` does not resolve | Fixed: `pertisk_ingress_ekub` uses `KUBERNETES_SERVICE_HOST` |
| Browser shows **localhost** cert on admin host | Ingress watcher failed → no TLS from Secret | Fix ekub; ensure `admin-*-tls` Secret exists (cert-manager) |

```bash
make docker-ingress-multi VERSION=<tag>
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy -n pertisk-eproxy --set image.tag=<tag>
kubectl rollout restart deployment -n pertisk-eproxy
```

## RBAC

ClusterRole grants:

- `ingresses`: get, list, watch, create, update, patch, delete
- `secrets`: get, list, watch (TLS)
- `namespaces`: list (Ingress form)
- `services`: get, list (Ingress form)
- `pods`: get, list, watch (dashboard — release namespace only)
- `leases`: get, list, watch, create, update, patch

## Example Ingress

```bash
kubectl apply -f examples/k8s-ingress.yaml
```

Ensure `spec.ingressClassName` matches `ingress.className` (default `pertisk-eproxy`).

To route to a Service in a different namespace than the Ingress object:
- Set annotation `pertisk.tech/backend-namespace` for a single default backend namespace.
- Or set `pertisk.tech/backend-namespaces` to a JSON map for per-service namespaces (for example `{"api":"team-a","admin":"team-b"}`).

The controller resolves upstreams as `<service>.<backend-namespace>.svc.cluster.local:<port>`.

## Example Gateway API Gateway + HTTPRoute

Enable Gateway API reconciliation first:

```bash
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy -n pertisk-eproxy \
  --set ingress.gatewayApiEnabled=true
```

Then apply the example Gateway + route:

```bash
kubectl apply -f examples/gateway-api-httproute.yaml
```

The route annotation `pertisk.io/gateway-class` must match your
`ingress.className` (default `pertisk-eproxy`).

**How routing works:** pertisk-eproxy does not attach HTTPRoutes via `parentRefs`.
It lists HTTPRoutes with the annotation above and programs the proxy LoadBalancer
(443/80). Optional `Gateway` resources supply TLS via listener `certificateRefs`
(matched to HTTPRoute hostnames, including wildcards like `*.example.com`).

**Verify after apply:**

```bash
kubectl get gatewayclass,gateway,httproute -n pertisk-eproxy
# GatewayClass ACCEPTED=True, Gateway Programmed=True (ingress image >= 0.5.48)

# Site should include certificate for your hostname (management API, auth required):
kubectl run gw-debug --rm -it -n pertisk-eproxy --image=curlimages/curl -- \
  sh -c 'TOKEN=$(curl -s -X POST http://pertisk-eproxy:9080/api/auth/login -H "Content-Type: application/json" -d "{\"username\":\"admin\",\"password\":\"admin\"}" | sed -n "s/.*\"token\":\"\\([^\"]*\\)\".*/\\1/p"); curl -s http://pertisk-eproxy:9080/api/sites -H "Authorization: Bearer $TOKEN" | grep admin.gateway'
```

### Dashboard `GET /api/kubernetes/pods` returns 403

The ServiceAccount needs `pods` **list** in the release namespace. Helm installs a namespaced **Role** (`*-dashboard`) plus ClusterRole rules.

```bash
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy -n pertisk-eproxy
kubectl auth can-i list pods \
  --as=system:serviceaccount:pertisk-eproxy:pertisk-eproxy -n pertisk-eproxy
```

If `can-i` is `no`, apply the chart again or check `rbac.create: true` in values.

## Chart notes

| Feature | pertisk-eproxy |
|---------|----------------|
| CRDs | Not installed by chart; optional Gateway API HTTPRoute reconcile when `ingress.gatewayApiEnabled=true` |
| Metrics | Dedicated `:9090` (`GET /metrics`; legacy `GET /api/metrics` on management) |
| Probes | `/api/ingress/live`, `/api/ingress/ready` (no auth; also `/api/ingress/status`) |
| Auth secret | `PERTISK_ADMIN` / `PERTISK_PASSWORD` (+ optional Auth0); stateless `ptskv1` bearer tokens across replicas |
| Listen ports | 8080 / 8443 in container (configurable via `controller.config`) |
