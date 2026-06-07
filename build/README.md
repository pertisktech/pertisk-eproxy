# Build and package

Scripts run from repo root (each script `cd`s to root automatically).

| Script | Purpose |
|--------|---------|
| `docker-harbor.sh` | Multi-arch proxy + ingress push via `make docker-harbor-multi` |
| `deploy-deb.sh` | Build Debian package, copy to remote host, install systemd unit |
| `deploy-rpm.sh` | Build RPM package, copy to remote host, install systemd unit |

Package internals live under `scripts/` (`build-release-linux.sh`, `build-deb-amd64.sh`, `build-rpm-amd64.sh`).

```bash
# Packages (output in release/)
make package-deb-amd64 VERSION=0.5.10
make package-rpm-amd64 VERSION=0.5.10

# Remote install (same env vars as before the folder move)
REMOTE_HOST=10.1.1.9 REMOTE_USER=root PACKAGE_VERSION=0.5.11 ./build/deploy-deb.sh
# or
REMOTE_HOST=10.1.1.9 VERSION=0.5.11 ./build/deploy-deb.sh 0.5.11
```

| Env | Default | Purpose |
|-----|---------|---------|
| `REMOTE_HOST` | `10.1.1.8` (deb) / `135.181.197.40` (rpm) | Target server |
| `REMOTE_USER` | `root` | SSH user |
| `PACKAGE_VERSION` or `VERSION` | `0.5.47` | Package version (CLI arg overrides) |
| `REMOTE_PATH` | `/tmp` | SCP destination on remote |
| `PACKAGE_NAME` | `pertisk-eproxy` | systemd unit / package name |
| `ADMIN_BUILD` | `1` | Build admin UI before packaging |
