# cert-manager + Cloudflare DNS for admin.homelab.thaidevops.co

TLS for `admin.homelab.thaidevops.co` and `*.homelab.thaidevops.co` using Let's Encrypt and Cloudflare DNS-01.

**Prerequisites:** cert-manager installed in the cluster (`kubectl get clusterissuer` or install from https://cert-manager.io/docs/installation/).

## 1. Create Cloudflare API token secret (do not commit the token)

You must use a **Cloudflare API Token** (not the Global API Key). Create one at [Cloudflare Dashboard → My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens) with:
- **Permissions:** Zone → DNS → Edit, Zone → Zone → Read
- **Zone Resources:** Include → Specific zone → `homelab.thaidevops.co`

Create the secret in namespace `pertisk-eproxy` with key **exactly** `api-token` (cert-manager sends it as `Authorization: Bearer <token>`). No extra spaces or newlines.

```bash
# Delete existing secret if you had the wrong key or Global API Key
kubectl delete secret cloudflare-dns -n pertisk-eproxy --ignore-not-found

# Create with API Token (paste your token, no quotes so no trailing space)
kubectl create secret generic cloudflare-dns \
  -n pertisk-eproxy \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN
```

If you get **6111: Invalid format for Authorization header**, you are likely using the Global API Key or the wrong secret key. Use an API Token and key `api-token` only.

## 2. Apply Issuer and Certificate

From the chart examples directory (or repo root with correct path):

```bash
# Issuer (Let's Encrypt + Cloudflare DNS-01)
kubectl apply -f deploy/helm/pertisk-ingress/examples/cert-manager-issuer-cloudflare.yaml -n pertisk-eproxy

# Certificate (admin.homelab.thaidevops.co + *.homelab.thaidevops.co)
kubectl apply -f deploy/helm/pertisk-ingress/examples/cert-manager-certificate-admin-homelab.yaml -n pertisk-eproxy
```

## 3. Wait for Certificate to be ready

```bash
kubectl get certificate -n pertisk-eproxy
kubectl describe certificate admin-homelab-tls -n pertisk-eproxy
```

When ready, the Secret `admin-homelab-tls` (type `kubernetes.io/tls`) will exist. The admin Ingress can use it via `spec.tls.secretName: admin-homelab-tls`.

## 4. Enable TLS on the admin Ingress

If using the chart with `adminIngress`:

```bash
# Add --set installCRDs=false if CRDs were applied manually (to avoid Helm adoption errors)
helm upgrade pertisk-ingress ./deploy/helm/pertisk-ingress -n pertisk-eproxy \
  --set adminIngress.tlsSecretName=admin-homelab-tls \
  --set installCRDs=false
```

If you applied the standalone Ingress example, uncomment the `tls` block in `ingress-admin-homelab.yaml` and set `secretName: admin-homelab-tls`, then apply.
