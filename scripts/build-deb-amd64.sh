#!/usr/bin/env bash
set -euo pipefail

PKG_NAME="${1:-pertisk-eproxy}"
VERSION="${2:-0.1.0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL_SRC="$ROOT_DIR/_build/prod/rel/pertisk_eproxy"
ERLANG_BUILD_PLATFORM="${ERLANG_BUILD_PLATFORM:-linux/amd64}"
export ERLANG_BUILD_PLATFORM
OUT_DIR="$ROOT_DIR/release"
WORK_DIR="$ROOT_DIR/_build/package-deb-amd64"
PKG_ROOT="$WORK_DIR/pkg"

copy_tree() {
  local SRC="$1"
  local DST="$2"
  if [ -e "$SRC" ]; then
    cp -R "$SRC" "$DST"
  fi
}

if [ ! -d "$REL_SRC" ]; then
  echo "Release directory not found at $REL_SRC. Run 'make release-amd64' first." >&2
  exit 1
fi

bash "$ROOT_DIR/scripts/verify-release-arch.sh" "$REL_SRC" x86_64

rm -rf "$WORK_DIR"
mkdir -p "$PKG_ROOT/opt" "$PKG_ROOT/lib/systemd/system" "$OUT_DIR"

copy_tree "$REL_SRC" "$PKG_ROOT/opt/$PKG_NAME"
copy_tree "$ROOT_DIR/config" "$PKG_ROOT/opt/$PKG_NAME/config"
copy_tree "$ROOT_DIR/priv" "$PKG_ROOT/opt/$PKG_NAME/priv"
mkdir -p "$PKG_ROOT/opt/$PKG_NAME/data/acme" "$PKG_ROOT/opt/$PKG_NAME/data/tls" "$PKG_ROOT/opt/$PKG_NAME/log"

cat > "$PKG_ROOT/lib/systemd/system/$PKG_NAME.service" <<EOF
[Unit]
Description=Pertisk eProxy
After=network.target

[Service]
Type=simple
User=$PKG_NAME
Group=$PKG_NAME
WorkingDirectory=/opt/$PKG_NAME
ExecStart=/opt/$PKG_NAME/bin/pertisk_eproxy foreground
Restart=on-failure
RestartSec=2
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

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
chown -R $PKG_NAME:$PKG_NAME /opt/$PKG_NAME || true

cat << 'MSG'
Pertisk eProxy installed.

Enable and start:
  sudo systemctl enable pertisk-eproxy --now

Service control:
  sudo systemctl status pertisk-eproxy
  sudo systemctl restart pertisk-eproxy

Runtime path:
  /opt/pertisk-eproxy
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
  -s dir -t deb --force
  -n "$PKG_NAME"
  -v "$VERSION"
  -a amd64
  --depends sqlite3
  --description "Pertisk Erlang reverse proxy"
  --maintainer "Pertisk Team"
  --license "MIT"
  --vendor "Pertisk"
  --category "net"
  --before-install "$WORK_DIR/preinstall.sh"
  --after-install "$WORK_DIR/postinstall.sh"
  --before-remove "$WORK_DIR/preremove.sh"
  --deb-systemd-enable
  -p "$OUT_DIR"
  -C "$PKG_ROOT" .
)

if command -v fpm >/dev/null 2>&1; then
  fpm "${FPM_ARGS[@]}"
elif command -v docker >/dev/null 2>&1; then
  echo "fpm not found locally; using Docker fallback to build .deb..."
  PKG_ROOT_REL="_build/package-deb-amd64/pkg"
  PRE_REL="_build/package-deb-amd64/preinstall.sh"
  POST_REL="_build/package-deb-amd64/postinstall.sh"
  PREREM_REL="_build/package-deb-amd64/preremove.sh"
  OUT_REL="release"
  docker run --rm \
    -v "$ROOT_DIR:/work" \
    -w /work \
    ubuntu:24.04 \
    bash -lc '
      set -euo pipefail
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y ruby ruby-dev build-essential
      gem install --no-document fpm
      fpm "$@"
    ' -- \
      -s dir -t deb --force \
      -n "$PKG_NAME" \
      -v "$VERSION" \
      -a amd64 \
      --description "Pertisk Erlang reverse proxy" \
      --maintainer "Pertisk Team" \
      --license "MIT" \
      --vendor "Pertisk" \
      --category "net" \
      --before-install "$PRE_REL" \
      --after-install "$POST_REL" \
      --before-remove "$PREREM_REL" \
      --deb-systemd-enable \
      -p "$OUT_REL" \
      -C "$PKG_ROOT_REL" .
else
  echo "fpm is required. Install with: gem install --no-document fpm (or install Docker for fallback)" >&2
  exit 1
fi

echo "DEB created in $OUT_DIR"
