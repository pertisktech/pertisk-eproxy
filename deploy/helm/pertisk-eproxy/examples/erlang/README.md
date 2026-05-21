# Pertisk Ingress examples

**Ingress mode** uses Kubernetes manifests for routing (`networking.k8s.io/v1` Ingress + TLS Secrets).  
**Proxy mode** uses SQLite (`data/proxy.db`) for sites/backends.

Compared with [pertisk-rproxy `pertisk-ingress`](https://github.com/pertisktech/pertisk-rproxy/tree/main/deploy/helm/pertisk-ingress): same admin Ingress pattern; eproxy reconciles **standard Ingress only** (CRDs are examples for later).

## Admin UI (pertisk-rproxy `pertisk-ingress-admin`)

Standard `networking.k8s.io/v1` Ingress, `ingressClassName: pertisk-eproxy`, Service port **9080**.

| File | Purpose |
|------|---------|
| **ingress-admin-erlang.yaml** | `admin.erlang.thaidevops.co` + TLS |
| **ingress-admin-1340p.yaml** | 1340p-style admin host |
| **ingress-admin-homelab.yaml** | homelab / orangepi hosts |
| Helm `adminIngress.enabled=true` | chart template (see `values.yaml`) |

```bash
kubectl apply -f ingress-admin-erlang.yaml
# or
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy -n pertisk-eproxy \
  --set adminIngress.enabled=true \
  --set adminIngress.host=admin.erlang.thaidevops.co \
  --set adminIngress.tlsSecretName=admin-erlang-tls
```

## App traffic (standard Ingress)

```bash
kubectl apply -f ingress-example.yaml -n my-namespace
```

- **ingress-example.yaml** – host → your app Service (e.g. port 80), optional TLS.

## CRD examples (not reconciled yet)

Mirror pertisk-rproxy; install CRDs from rproxy chart if you want to experiment. The Erlang controller does **not** watch these yet.

```bash
kubectl apply -f pertisk-backend-example.yaml
kubectl apply -f pertisk-ingress-crd-example.yaml
```

## cert-manager

- **cert-manager-*.yaml**, **cert-manager-README.md** – TLS for admin or app hosts (Cloudflare DNS).

## Summary

| Example | Type | Reconciled by eproxy |
|---------|------|----------------------|
| ingress-example | Ingress (app) | Yes |
| ingress-admin-* | Ingress (admin :9080) | Yes |
| pertisk-backend-example | CRD | No |
| pertisk-ingress-crd-example | CRD | No |
