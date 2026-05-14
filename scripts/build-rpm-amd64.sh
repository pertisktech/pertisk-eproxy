#!/usr/bin/env bash
set -euo pipefail

PKG_NAME="${1:-pertisk-eproxy}"
VERSION="${2:-0.1.0}"
VERSION="${VERSION#v}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL_SRC="$ROOT_DIR/_build/prod/rel/pertisk_eproxy"
OUT_DIR="$ROOT_DIR/release"
WORK_DIR="$ROOT_DIR/_build/package-rpm-amd64"
PKG_ROOT="$WORK_DIR/pkg"

# Helper: Check if binary is Linux ELF format
is_linux_elf() {
  local bin="$1"
  if [ ! -f "$bin" ]; then
    return 1
  fi
  file "$bin" | grep -q "ELF 64-bit LSB" 2>/dev/null || return 1
  return 0
}

# Helper: Build release in Linux Docker container
build_release_in_docker() {
  echo "Building release inside rockylinux:9 for x86_64..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is required to build x86_64 release on non-Linux platform." >&2
    exit 1
  fi
  
  docker run --rm \
    -v "$ROOT_DIR:/work" \
    -w /work \
    rockylinux:9 \
    bash -lc '
      set -euo pipefail
      dnf install -y epel-release
      # EPEL 9 has no erlang-devel RPM; erl_nif.h and friends ship in erlang-erts (pulled in by erlang).
      # EL 9 AppStream/EPEL may not ship a rebar3 RPM; install a known release to PATH.
      dnf install -y erlang gcc gcc-c++ make git cmake openssl-devel wget
      wget -qO /usr/local/bin/rebar3 https://github.com/erlang/rebar3/releases/download/3.24.0/rebar3
      chmod +x /usr/local/bin/rebar3
      make clean
      make release
    ' || {
      echo "ERROR: Docker build of release failed." >&2
      exit 1
    }
}

# Check if release exists and is Linux-compatible
if [ ! -d "$REL_SRC" ] || ! is_linux_elf "$REL_SRC/erts-16.4/bin/erlexec"; then
  echo "Release not found or not built for Linux. Building now..."
  build_release_in_docker
  
  if [ ! -d "$REL_SRC" ]; then
    echo "ERROR: Release build failed. Directory $REL_SRC not found." >&2
    exit 1
  fi
fi

rm -rf "$WORK_DIR"
mkdir -p "$PKG_ROOT/opt" "$PKG_ROOT/lib/systemd/system" "$OUT_DIR"

cp -R "$REL_SRC" "$PKG_ROOT/opt/$PKG_NAME"
mkdir -p "$PKG_ROOT/opt/$PKG_NAME/config"
cp "$ROOT_DIR/packaging/proxy.package.json" "$PKG_ROOT/opt/$PKG_NAME/config/proxy.json"

sed "s/@PKG_NAME@/$PKG_NAME/g" "$ROOT_DIR/packaging/pertisk-eproxy.service.in" \
  > "$PKG_ROOT/lib/systemd/system/$PKG_NAME.service"

cat > "$WORK_DIR/preinstall.sh" <<EOF
#!/bin/sh
set -e
if ! getent group $PKG_NAME >/dev/null 2>&1; then
  groupadd --system $PKG_NAME
fi
if ! getent passwd $PKG_NAME >/dev/null 2>&1; then
  useradd --system --gid $PKG_NAME --home-dir /opt/$PKG_NAME --shell /usr/sbin/nologin --comment "Pertisk eProxy" $PKG_NAME
fi
exit 0
EOF
chmod +x "$WORK_DIR/preinstall.sh"

cat > "$WORK_DIR/postinstall.sh" <<EOF
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl enable $PKG_NAME || true
fi
mkdir -p /opt/$PKG_NAME/log /opt/$PKG_NAME/data || true
chown -R $PKG_NAME:$PKG_NAME /opt/$PKG_NAME || true

cat << 'MSG'
Pertisk eProxy installed — this package is the edge reverse proxy (HTTP, HTTPS,
HTTP/3 over QUIC). You do not need nginx in front for the same listener layout.

1) Start the service
   sudo systemctl enable pertisk-eproxy --now

2) Default listeners (see /opt/pertisk-eproxy/config/proxy.json)
   HTTP:             TCP 80   (all interfaces)
   HTTPS + HTTP/2:   TCP 443
   HTTP/3 (QUIC):    UDP 443  (same port as HTTPS)
   Admin UI + API:   TCP 127.0.0.1:9080 (localhost only; not exposed as 0.0.0.0)

3) Open the firewall / cloud security group (example: firewalld)
   sudo firewall-cmd --permanent --add-service=http
   sudo firewall-cmd --permanent --add-service=https
   sudo firewall-cmd --permanent --add-port=443/udp
   sudo firewall-cmd --reload
   (Do not open 9080 publicly unless you set management_addr to 0.0.0.0 in proxy.json.)

4) Admin UI from your laptop (SSH port forward)
   ssh -L 9080:127.0.0.1:9080 root@YOUR_SERVER_IP
   Then open: http://127.0.0.1:9080/

5) Runtime config
   data/proxy.db overrides proxy.json after first start. If upgrades loop, back up then:
   sudo rm -f /opt/pertisk-eproxy/data/proxy.db && sudo systemctl restart pertisk-eproxy

systemd grants CAP_NET_BIND_SERVICE so the service user can bind 80/443/443-udp.

If the service still exits immediately:
  sudo journalctl -u pertisk-eproxy -b -n 100 --no-pager
  sudo tail -n 80 /opt/pertisk-eproxy/log/proxy.log
  sudo tail -n 80 /opt/pertisk-eproxy/log/error.log
  sudo ls -la /opt/pertisk-eproxy/log/erl_crash.dump

Runtime: /opt/pertisk-eproxy
MSG
exit 0
EOF
chmod +x "$WORK_DIR/postinstall.sh"

cat > "$WORK_DIR/preremove.sh" <<EOF
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop $PKG_NAME 2>/dev/null || true
  systemctl disable $PKG_NAME 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$WORK_DIR/preremove.sh"

FPM_ARGS=(
  -s dir -t rpm --force
  -n "$PKG_NAME"
  -v "$VERSION"
  -a x86_64
  --description "Pertisk Erlang reverse proxy"
  --maintainer "Pertisk Team"
  --license "MIT"
  --vendor "Pertisk"
  --category "net"
  --before-install "$WORK_DIR/preinstall.sh"
  --after-install "$WORK_DIR/postinstall.sh"
  --before-remove "$WORK_DIR/preremove.sh"
  -p "$OUT_DIR"
  -C "$PKG_ROOT" .
)

if command -v fpm >/dev/null 2>&1; then
  fpm "${FPM_ARGS[@]}"
elif command -v docker >/dev/null 2>&1; then
  echo "fpm not found locally; using Docker fallback to build .rpm..."
  PKG_ROOT_REL="_build/package-rpm-amd64/pkg"
  PRE_REL="_build/package-rpm-amd64/preinstall.sh"
  POST_REL="_build/package-rpm-amd64/postinstall.sh"
  PREREM_REL="_build/package-rpm-amd64/preremove.sh"
  OUT_REL="release"
  docker run --rm \
    -v "$ROOT_DIR:/work" \
    -w /work \
    rockylinux:9 \
    bash -lc '
      set -euo pipefail
      dnf install -y ruby ruby-devel gcc rpm-build
      gem install --no-document fpm
      fpm "$@"
    ' -- \
      -s dir -t rpm --force \
      -n "$PKG_NAME" \
      -v "$VERSION" \
      -a x86_64 \
      --description "Pertisk Erlang reverse proxy" \
      --maintainer "Pertisk Team" \
      --license "MIT" \
      --vendor "Pertisk" \
      --category "net" \
      --before-install "$PRE_REL" \
      --after-install "$POST_REL" \
      --before-remove "$PREREM_REL" \
      -p "$OUT_REL" \
      -C "$PKG_ROOT_REL" .
else
  echo "fpm is required. Install with: gem install --no-document fpm (or install Docker for fallback)" >&2
  exit 1
fi

echo "RPM created in $OUT_DIR"
