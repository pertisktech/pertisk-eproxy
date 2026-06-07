# Docker images

Build context is always the **repository root** (`.`).

| File | Image | Mode |
|------|-------|------|
| `Dockerfile.proxy` | `harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy` | Proxy + admin UI (SQLite config) |
| `Dockerfile.ingress` | `harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/ingress` | Kubernetes ingress controller |

```bash
# Single-arch (local)
make docker-ingress VERSION=0.5.10
make docker-proxy VERSION=0.5.10

# Multi-arch push to Harbor
make docker-ingress-multi VERSION=0.5.10
make docker-harbor-multi VERSION=0.5.10

# Or use the wrapper
./build/docker-harbor.sh 0.5.10
```

Equivalent explicit buildx:

```bash
docker buildx build --push -f docker/Dockerfile.ingress -t harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/ingress:0.5.10 .
```
