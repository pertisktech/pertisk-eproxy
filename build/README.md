# Build and package

Scripts run from repo root (each script `cd`s to root automatically).

| Script | Purpose |
|--------|---------|
| `docker-harbor.sh` | Multi-arch proxy + ingress push via `make docker-harbor-multi` |
| `deploy-deb.sh` | Build Debian package, copy to remote host, install systemd unit |
| `deploy-rpm.sh` | Build RPM package, copy to remote host, install systemd unit |
| `publish-helm-eproxy.sh` | Package and upload `pertisk-eproxy` chart to [chart.cloud.pertisksoft.net](https://chart.cloud.pertisksoft.net/) |

Package internals live under `scripts/` (`build-release-linux.sh`, `build-deb-amd64.sh`, `build-rpm-amd64.sh`).

```bash
# Packages (output in release/)
make package-deb-amd64 VERSION=0.5.10
make package-rpm-amd64 VERSION=0.5.10

# Remote install (same env vars as before the folder move)
REMOTE_HOST=YOUR_HOST REMOTE_USER=root PACKAGE_VERSION=0.5.11 ./build/deploy-deb.sh
# or
REMOTE_HOST=YOUR_HOST VERSION=0.5.11 ./build/deploy-deb.sh 0.5.11
```

RPM builds pin the release image to `hexpm/erlang:27.0.1-debian-bullseye-20240701-slim` by default so bundled `erts` stays compatible with older glibc hosts such as EL9. Override with `RPM_RELEASE_BUILD_IMAGE=...` only if the replacement image keeps the runtime ABI at or below `GLIBC_2.34` and `GLIBCXX_3.4.29`.

| Env | Default | Purpose |
|-----|---------|---------|
| `REMOTE_HOST` | `YOUR_HOST` (deb) / `YOUR_HOST` (rpm) | Target server |
| `REMOTE_USER` | `root` | SSH user |
| `PACKAGE_VERSION` or `VERSION` | `0.5.47` | Package version (CLI arg overrides) |
| `REMOTE_PATH` | `/tmp` | SCP destination on remote |
| `PACKAGE_NAME` | `pertisk-eproxy` | systemd unit / package name |
| `ADMIN_BUILD` | `1` | Build admin UI before packaging |
