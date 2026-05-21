# Pertisk Ingress examples

All of these show up in the **Admin UI** (Sites / Backends) after the controller reconciles. Use either **CRDs** or **standard Ingress**, or both.

## Admin UI (same as pertisk-rproxy `pertisk-ingress-admin`)

Use **standard** `networking.k8s.io/v1` Ingress with `ingressClassName: pertisk-eproxy`, backend Service port **9080** (management API). Not the `PertiskIngress` CRD file.

| File | Purpose |
|------|---------|
| **ingress-admin-1340p.yaml** | 1340p-style admin host + TLS |
| **ingress-admin-homelab.yaml** | homelab/orangepi hosts |
| Helm `adminIngress.enabled=true` | chart renders the same Ingress (see values.yaml) |

Or enable in Helm (equivalent to rproxy):

```bash
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy -n pertisk-eproxy \
  --set adminIngress.enabled=true \
  --set adminIngress.host=admin.1340p.thaidevops.co \
  --set adminIngress.tlsSecretName=admin-1340p-tls
```

## CRD examples (PertiskBackend + PertiskIngress) — not reconciled yet

These mirror pertisk-rproxy CRDs for documentation; the Erlang controller only watches **standard Ingress** today.

```bash
kubectl apply -f pertisk-backend-example.yaml
kubectl apply -f pertisk-ingress-example.yaml
```

- **pertisk-backend-example.yaml** – `PertiskBackend` with upstreams and health path (namespace: default).
- **pertisk-ingress-example.yaml** – `PertiskIngress` that references the backend and optional TLS (namespace: default).

## Standard Ingress example (networking.k8s.io)

Standard Kubernetes Ingress with `ingressClassName: pertisk-eproxy`. Also appears in the Admin UI.

```bash
kubectl apply -f ingress-example.yaml
# Or with a specific namespace:
kubectl apply -f ingress-example.yaml -n my-namespace
```

- **ingress-example.yaml** – minimal Ingress (host + path + Service backend). Use this so “other” (non-CRD) Ingress shows in the list.

## Admin / TLS examples

- **ingress-admin-homelab.yaml** – Ingress that routes a host to the management UI (port 9080); optional TLS.
- **cert-manager-*.yaml** and **cert-manager-README.md** – TLS with cert-manager and Cloudflare DNS.

## Summary

| Example                 | Type        | Shows in Admin UI |
|-------------------------|------------|-------------------|
| pertisk-backend-example | CRD        | Yes (Backends)    |
| pertisk-ingress-example | CRD        | Yes (Sites)       |
| ingress-example         | Ingress    | Yes (Sites + Backends) |
| ingress-admin-homelab    | Ingress    | Yes (Sites + Backends) |

Both **CRDs** and **standard Ingress** (with `ingressClassName: pertisk-eproxy`) are reconciled and appear in the same Backends/Sites list in the Admin UI.
