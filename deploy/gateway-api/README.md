# Gateway API — admin.erlang.pertisk.com (pertisk-eproxy)

Expose the **Erlang** ingress controller management UI at `https://admin.erlang.pertisk.com`.

| Controller | Admin host | Manifest |
|------------|------------|----------|
| **pertisk-eproxy** (Erlang) | `admin.erlang.pertisk.com` | this directory |
| **pertisk-rproxy** (Rust) | `admin.gateway.pertisk.com` | pertisk-rproxy repo |

Do not point both controllers at the same hostname.

## Deploy with h255.sh

Gateway API admin (disable chart `adminIngress`):

```bash
export KUBECONFIG=/Users/nat/.kube/talos-255-prod-cluster-kubeconfig.yaml
ADMIN_VIA_GATEWAY=true VERSION=0.5.98 ./deploy/h255.sh
```

Classic Ingress admin (default):

```bash
VERSION=0.5.98 ./deploy/h255.sh
```

## Manual apply

```bash
kubectl apply -f deploy/gateway-api/admin-gateway.yaml -n pertisk-eproxy
```

Remove stale duplicates if you migrated from `admin.gateway.pertisk.com` on this namespace:

```bash
kubectl delete httproute admin-gateway-httproute gateway pertisk-gateway -n pertisk-eproxy --ignore-not-found
```

## Verify

```bash
kubectl get gateway,httproute -n pertisk-eproxy
curl -sI https://admin.erlang.pertisk.com/api/ingress/live | grep -iE '^(HTTP/|alt-svc|server)'
```
