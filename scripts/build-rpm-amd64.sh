#!/usr/bin/env bash
set -euo pipefail

PKG_NAME="${1:-pertisk-eproxy}"
VERSION="${2:-0.1.0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL_SRC="$ROOT_DIR/_build/prod/rel/pertisk_eproxy"
OUT_DIR="$ROOT_DIR/release"
WORK_DIR="$ROOT_DIR/_build/package-rpm-amd64"
PKG_ROOT="$WORK_DIR/pkg"

read_start_erl_data() {
  local START_ERL_FILE="$1"
  local erts_vsn=""
  local rel_vsn=""

  if [ ! -f "$START_ERL_FILE" ]; then
    echo "Missing start_erl.data at $START_ERL_FILE" >&2
    return 1
  fi

  # start_erl.data may miss trailing newline; do not rely on bare read under set -e.
  IFS=' ' read -r erts_vsn rel_vsn < "$START_ERL_FILE" || true

  if [ -z "$erts_vsn" ] || [ -z "$rel_vsn" ]; then
    echo "Invalid start_erl.data content in $START_ERL_FILE" >&2
    return 1
  fi

  printf '%s %s\n' "$erts_vsn" "$rel_vsn"
}

copy_tree() {
  local SRC="$1"
  local DST="$2"
  if [ -e "$SRC" ]; then
    cp -R "$SRC" "$DST"
  fi
}

patch_release_wrapper_ld_library_path() {
  local WRAPPER_PATH="$1"
  local TMP_PATH

  [ -f "$WRAPPER_PATH" ] || return 0

  TMP_PATH="${WRAPPER_PATH}.tmp"
  awk '
    {
      if ($0 == "export LD_LIBRARY_PATH=\"$ERTS_DIR/lib:$LD_LIBRARY_PATH\"") {
        print "export LD_LIBRARY_PATH=\"$ROOTDIR/lib/runtime:$ROOTDIR/lib/openssl:$ERTS_DIR/lib:$LD_LIBRARY_PATH\""
      } else {
        print $0
      }
    }
  ' "$WRAPPER_PATH" > "$TMP_PATH"
  mv "$TMP_PATH" "$WRAPPER_PATH"
  chmod +x "$WRAPPER_PATH"
}

if [ ! -d "$REL_SRC" ]; then
  echo "Release directory not found at $REL_SRC. Run 'make release' first." >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$PKG_ROOT/opt" "$PKG_ROOT/usr/lib/systemd/system" "$OUT_DIR"

copy_tree "$REL_SRC" "$PKG_ROOT/opt/$PKG_NAME"
bash "$ROOT_DIR/scripts/bundle-openssl-for-rpm.sh" "$PKG_ROOT/opt/$PKG_NAME"
bash "$ROOT_DIR/scripts/bundle-runtime-libs-for-rpm.sh" "$PKG_ROOT/opt/$PKG_NAME"
copy_tree "$ROOT_DIR/config" "$PKG_ROOT/opt/$PKG_NAME/config"
copy_tree "$ROOT_DIR/priv" "$PKG_ROOT/opt/$PKG_NAME/priv"
# Do not package data/ or log/ — would overwrite production SQLite and ACME state on upgrade.
mkdir -p "$PKG_ROOT/opt/$PKG_NAME/data/acme" "$PKG_ROOT/opt/$PKG_NAME/data/tls" "$PKG_ROOT/opt/$PKG_NAME/log"

patch_release_wrapper_ld_library_path "$PKG_ROOT/opt/$PKG_NAME/bin/pertisk_eproxy"

read -r ERTS_VSN REL_VSN < <(read_start_erl_data "$PKG_ROOT/opt/$PKG_NAME/releases/start_erl.data")

ERLEXEC_PATH="/opt/$PKG_NAME/erts-${ERTS_VSN}/bin/erlexec"
BOOT_PATH="/opt/$PKG_NAME/releases/${REL_VSN}/pertisk_eproxy"
SYS_CONFIG_PATH="/opt/$PKG_NAME/releases/${REL_VSN}/sys.config"
VM_ARGS_PATH="/opt/$PKG_NAME/releases/${REL_VSN}/vm.args"

cat > "$PKG_ROOT/usr/lib/systemd/system/$PKG_NAME.service" <<EOF
[Unit]
Description=Pertisk eProxy
After=network.target

[Service]
Type=simple
User=$PKG_NAME
Group=$PKG_NAME
WorkingDirectory=/opt/$PKG_NAME
Environment=ROOTDIR=/opt/$PKG_NAME
Environment=BINDIR=${ERLEXEC_PATH%/erlexec}
Environment=EMU=beam
Environment=PROGNAME=erl
Environment=LD_LIBRARY_PATH=/opt/$PKG_NAME/lib/runtime:/opt/$PKG_NAME/lib/openssl
# Bind HTTP :80 / HTTPS :443 / QUIC without running as root (see proxy.json ports).
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=${ERLEXEC_PATH} -noinput +Bd -boot ${BOOT_PATH} -mode embedded -boot_var SYSTEM_LIB_DIR /opt/$PKG_NAME/lib -config ${SYS_CONFIG_PATH} -args_file ${VM_ARGS_PATH} -- foreground
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

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
DATA_DIR="/opt/$PKG_NAME/data"
mkdir -p "\$DATA_DIR/acme" "\$DATA_DIR/tls" "/opt/$PKG_NAME/log"
if [ -f "\$DATA_DIR/proxy.db" ]; then
  echo "Deploy: existing data/proxy.db kept (schema migrated on service start)"
else
  echo "First install: data/proxy.db will be created on first service start"
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "WARNING: sqlite3 not found in PATH. Install sqlite3 (e.g. dnf install sqlite) before starting $PKG_NAME." >&2
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl enable $PKG_NAME || true
fi
chown -R $PKG_NAME:$PKG_NAME /opt/$PKG_NAME || true

cat << MSG
Pertisk eProxy installed (SQLite storage).

Enable and start:
  sudo systemctl enable $PKG_NAME --now

Runtime path:
  /opt/$PKG_NAME
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
  --depends sqlite3
  --depends openssl
  --depends libstdc++
  --description "Pertisk Erlang reverse proxy (bundled OpenSSL 3 for OTP crypto NIF)"
  --maintainer "Pertisk Team"
  --license "MIT"
  --vendor "Pertisk"
  --category "net"
  --rpm-os linux
  --before-install "$WORK_DIR/preinstall.sh"
  --after-install "$WORK_DIR/postinstall.sh"
  --before-remove "$WORK_DIR/preremove.sh"
  --config-files "/opt/$PKG_NAME/config/proxy.json"
  --config-files "/opt/$PKG_NAME/config/sys.config"
  --config-files "/opt/$PKG_NAME/config/vm.args"
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
    ubuntu:24.04 \
    bash -lc '
      set -euo pipefail
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y rpm ruby ruby-dev build-essential
      gem install --no-document fpm
      fpm "$@"
    ' -- \
      -s dir -t rpm --force \
      -n "$PKG_NAME" \
      -v "$VERSION" \
      -a x86_64 \
      --depends sqlite3 \
      --depends openssl \
      --depends libstdc++ \
      --description "Pertisk Erlang reverse proxy (bundled OpenSSL 3 for OTP crypto NIF)" \
      --maintainer "Pertisk Team" \
      --license "MIT" \
      --vendor "Pertisk" \
      --category "net" \
      --rpm-os linux \
      --before-install "$PRE_REL" \
      --after-install "$POST_REL" \
      --before-remove "$PREREM_REL" \
      --config-files "/opt/$PKG_NAME/config/proxy.json" \
      --config-files "/opt/$PKG_NAME/config/sys.config" \
      --config-files "/opt/$PKG_NAME/config/vm.args" \
      -p "$OUT_REL" \
      -C "$PKG_ROOT_REL" .
else
  echo "fpm is required. Install with: gem install --no-document fpm (or install Docker for fallback)" >&2
  exit 1
fi

echo "RPM created in $OUT_DIR"