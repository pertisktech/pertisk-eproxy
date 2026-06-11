# Run the ingress controller locally

Run pertisk-eproxy in **ingress** mode with `config/ingress.json`.

## Start ingress mode

```bash
make run-ingress
```

Equivalent:

```bash
PERTISK_MODE=ingress PERTISK_CONFIG_FILE=config/ingress.json rebar3 shell --apps pertisk_eproxy
```

## Management API (read-only)

```bash
curl -s http://127.0.0.1:9080/api/ingress/status | jq .
curl -s http://127.0.0.1:9080/api/ingress/resources | jq .
```

## Deploy to Kubernetes

For a full cluster install, use the Helm chart:

```bash
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy \
  -n pertisk-eproxy --create-namespace
```

See [Deploy with Helm](../guides/deploy-with-helm.md) and
[Kubernetes reconciliation](../concepts/kubernetes-ingress.md).

## What's next

- [Tune ingress throughput](../guides/tune-ingress-throughput.md)
- [Ingress implementation notes](../K8S_INGRESS_IMPLEMENTATION.md)
