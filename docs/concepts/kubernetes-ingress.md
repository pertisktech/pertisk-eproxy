# Kubernetes ingress

In **ingress** mode, pertisk-eproxy reconciles standard `networking.k8s.io/v1`
Ingress resources into in-memory sites and backends.

## Reconciliation flow

1. `pertisk_ingress_watcher` watches Ingress and TLS Secret objects (ekub).
2. `pertisk_ingress_reconciler` transforms each Ingress into site/backend entries.
3. `pertisk_eproxy_config:sync_ingress/2` updates the hot config (no SQLite).
4. TLS material from Secrets is written under `data/` for listener reload.
5. Leader election (`pertisk_ingress_leader`) ensures one writer reconciles at a time.

## Ingress class

Only Ingresses with `spec.ingressClassName` matching `pertisk-eproxy` (Helm default)
are reconciled. Override via `ingress.className` in Helm values.

## Cross-namespace backends

Annotations:

- `pertisk.tech/backend-namespace` — default backend namespace
- `pertisk.tech/backend-namespaces` — JSON map of service name → namespace

## Probes

| Path | Purpose |
|------|---------|
| `/api/ingress/live` | Liveness |
| `/api/ingress/ready` | Readiness |
| `/api/ingress/status` | Controller status snapshot |

## Further reading

- [K8S_INGRESS_IMPLEMENTATION.md](../K8S_INGRESS_IMPLEMENTATION.md) — design notes
- [Deploy with Helm](../guides/deploy-with-helm.md)
