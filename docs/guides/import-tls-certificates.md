# Import TLS certificates

## Admin API

```bash
curl -X POST http://127.0.0.1:9080/api/certificates/import \
  -H 'Content-Type: application/json' \
  -d '{"label":"my-cert","cert_pem":"...","key_pem":"..."}'
```

## Listener PEM files

Set in config or via API:

```json
{
  "tls_cert_file": "priv/tls/listener.pem",
  "tls_key_file": "priv/tls/listener.key"
}
```

`POST /api/tls/listener` updates in-memory paths; HTTPS may need listener reload.

## Kubernetes ingress

TLS comes from `Secret` resources referenced by Ingress `tls` blocks. Ensure
`tls.crt` includes the **full chain** for HTTP/3 (Chrome is strict on QUIC).

## ACME

Automatic DNS-01 issuance is documented in [README_SQLITE.md](../README_SQLITE.md).
