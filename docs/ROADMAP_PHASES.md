# Product roadmap — implementation phases

This document records the phased roadmap for pertisk-eproxy (production-grade
ingress controller) and what is **implemented in this repository** as of the
current development branch.

Phases are ordered by priority: trust and CI first, then ingress parity,
HTTP/3 operations, operator UX, and strategic features.

---

## Phase 0 — Security and CI

**Goal:** Safe defaults, automated verification, no secrets in examples.

### Implemented

| Item | Location / how to use |
|------|------------------------|
| **CI workflow** | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) — `rebar3 compile`, `rebar3 eunit`, admin build, Helm lint, Playwright smoke tests |
| **Strong password gate (Helm)** | `auth.requireStrongPassword` in chart values; fails install when password is empty, `admin`, or &lt; 12 chars |
| **Production values profile** | [`deploy/helm/pertisk-eproxy/values-production.yaml`](../deploy/helm/pertisk-eproxy/values-production.yaml) — PDB, ServiceMonitor, `externalTrafficPolicy: Local`, strong password required |
| **Sanitized config example** | [`config/sys.config.example`](../config/sys.config.example) — no real credentials |
| **Optional NetworkPolicy** | `networkPolicy.enabled` in chart; template in `templates/networkpolicy.yaml` |

### Example — production install

```bash
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy \
  -f deploy/helm/pertisk-eproxy/values-production.yaml \
  --set auth.password="$(openssl rand -base64 24)" \
  -n pertisk-eproxy --create-namespace
```

### Not yet implemented

- Dialyzer / cover gates in CI
- Kind or minikube end-to-end smoke job in CI
- Automatic secret rotation

---

## Phase 1 — Ingress credibility

**Goal:** Behaviour and observability comparable to mainstream ingress controllers.

### Implemented

| Item | Details |
|------|---------|
| **Ingress annotations** | See [Ingress annotations](#ingress-annotations) below |
| **Ingress `.status`** | `pertisk_ingress_status_patcher` — leader patches `loadBalancer` from the publish Service and `Programmed` condition |
| **Controller Prometheus metrics** | `pertisk_ingress_metrics` — `pertisk_ingress_reconcile_total`, `pertisk_ingress_sites`, `pertisk_ingress_backends`, `pertisk_ingress_tls_secrets`, `pertisk_ingress_leader` |
| **Resource backends** | `pertisk.io/resource-upstreams` JSON map (`resource name` → `host:port`) |
| **RBAC** | `ingresses/status` patch; Gateway API `httproutes` list/watch (Phase 4) |

### Ingress annotations

Preferred prefix is `pertisk.io/`. Legacy `pertisk.tech/` aliases remain for
backend namespace annotations.

| Annotation | Purpose |
|------------|---------|
| `pertisk.io/backend-namespace` | Default backend Service namespace |
| `pertisk.io/backend-namespaces` | JSON map: service name → namespace |
| `pertisk.io/advertise-http3` | `true` / `false` — Alt-Svc for HTTP/3 |
| `pertisk.io/sse-early-flush` | Site-wide SSE early flush |
| `pertisk.io/sse-early-flush-paths` | Per-path SSE flush map |
| `pertisk.io/rewrite-target` | Path rewrite prefix for routes |
| `nginx.ingress.kubernetes.io/rewrite-target` | Alias for rewrite |
| `pertisk.io/load-balancer` | `round_robin`, `least_connections`, `ip_hash` |
| `pertisk.io/health-path` | Backend health check path |
| `pertisk.io/resource-upstreams` | Resource backend → upstream address map |
| `pertisk.io/auth-url` | External auth subrequest URL (Phase 4) |
| `nginx.ingress.kubernetes.io/auth-url` | Alias for auth URL |
| `pertisk.io/rate-limit-rps` | Per-Ingress rate limit (requests/s) |
| `pertisk.io/rate-limit-burst` | Per-Ingress burst size |

Publish Service for status: set `ingress.publishService` or env
`PERTISK_K8S_PUBLISH_SERVICE` (defaults to Helm release fullname).

### Not yet implemented

- Full nginx annotation parity (canary, session affinity annotations, etc.)
- Admission webhooks for Ingress validation

---

## Phase 2 — HTTP/3 production playbook

**Goal:** Documented, deployable HTTP/3 behind cloud load balancers.

### Implemented

| Item | Details |
|------|---------|
| **H3 single-replica profile** | [`values-h3-single.yaml`](../deploy/helm/pertisk-eproxy/values-h3-single.yaml) — `replicaCount: 1`, QUIC on, `externalTrafficPolicy: Local` |
| **Production profile** | QUIC enabled in `values-production.yaml` |
| **H3 verify script in CI** | `bash -n scripts/verify_h3_params.sh` in CI |
| **Chart comments** | Default `values.yaml` documents H3 + LB constraints |

See also [QUIC.md](QUIC.md) and [Tune ingress throughput](guides/tune-ingress-throughput.md).

### Not yet implemented

- Automated `verify_h3_params.sh` against a live endpoint in CI
- Helm post-install H3 connectivity check

---

## Phase 3 — Operator experience

**Goal:** Day-2 operations without shell access to pods.

### Implemented

| Item | Details |
|------|---------|
| **API tokens (ingress mode)** | `GET/POST /api/admin/api-token` — env-backed; POST rotates runtime token (persist via `PERTISK_API_TOKEN` in Secret) |
| **Certificate renew** | `POST /api/certificates/:id/renew` — queues ACME scan for sites using that cert |
| **Certificate delete** | `DELETE /api/certificates/:id` — wired in admin UI |
| **PDB + ServiceMonitor** | Enabled in `values-production.yaml` |
| **Playwright smoke tests** | `admin/e2e/smoke.spec.ts`; `npm run test:e2e` in CI |
| **Dashboard TLS validation** | Client-side cert resolution + `/api/certificates` (see admin `tlsSiteValidation.ts`) |

### Not yet implemented

- Password change in ingress mode (still read-only / not persisted to Secret)
- Full cert lifecycle UI for ingress-mode K8s TLS secrets
- ServiceMonitor enabled by default in base chart (only in production profile)

---

## Phase 4 — Strategic features

**Goal:** Observability propagation, auth integration, Gateway API, traffic shaping.

### Implemented

| Item | Module / config |
|------|-----------------|
| **Global rate limiting** | `pertisk_eproxy_rate_limit` — `rate_limit_enabled`, `rate_limit_rps`, `rate_limit_burst` in config |
| **Per-site rate limits** | Ingress annotations; applied on HTTP/1–2 and HTTP/3 |
| **Rate limit metrics** | `pertisk_eproxy_rate_limit_denied_total{host,site}` |
| **W3C trace context** | `pertisk_eproxy_tracing` — `traceparent` inject on upstream; `otel_enabled`, `otel_service_name` in config |
| **External auth** | `pertisk_eproxy_external_auth` — forward-auth style subrequest before proxy |
| **H3 full health (authenticated)** | `GET /api/health` on HTTP/3 returns full JSON when `Authorization: Bearer` is present |
| **Gateway API HTTPRoute** | `pertisk_gateway_reconciler` — opt-in via `ingress.gatewayApiEnabled` or `PERTISK_GATEWAY_API_ENABLED=true`; annotation `pertisk.io/gateway-class` |

### Gateway API example

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: default
  annotations:
    pertisk.io/gateway-class: pertisk-eproxy
spec:
  hostnames:
    - api.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: backend
          port: 8080
```

Helm:

```yaml
ingress:
  gatewayApiEnabled: true
```

### Tracing example (`ingress.json` / proxy config)

```json
{
  "otel_enabled": true,
  "otel_service_name": "pertisk-eproxy"
}
```

When enabled, new `traceparent` headers are generated if the client did not send
one; existing W3C trace context is always propagated upstream.

### Not yet implemented

- OTLP span export (Jaeger, Tempo, Honeycomb)
- Full Gateway API (Gateway, GRPCRoute, TLS on Gateway resources)
- OAuth2 / OIDC built-in (use `auth-url` to an external auth service today)
- WAF / OPA integration

---

## Quick reference — Helm value profiles

| File | Use case |
|------|----------|
| `values.yaml` | Default dev / homelab (weak default password allowed) |
| `values-production.yaml` | Production: strong password, PDB, metrics, Local policy |
| `values-h3-single.yaml` | Reliable HTTP/3 behind cloud LB (single replica) |

---

## Related docs

- [Kubernetes ingress concepts](concepts/kubernetes-ingress.md)
- [Deploy with Helm](guides/deploy-with-helm.md)
- [Prometheus metrics](guides/prometheus-metrics.md)
- [K8S ingress implementation notes](K8S_INGRESS_IMPLEMENTATION.md)
