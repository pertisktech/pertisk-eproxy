#!/usr/bin/env bash

set -euo pipefail

# Configuration (override via env vars or first CLI arg for version)
REMOTE_HOST="${REMOTE_HOST:-135.181.197.40}"
REMOTE_USER="${REMOTE_USER:-root}"
PACKAGE_NAME="${PACKAGE_NAME:-pertisk-eproxy}"
RAW_PACKAGE_VERSION="${1:-${PACKAGE_VERSION:-${VERSION:-0.5.47}}}"
PACKAGE_VERSION="${RAW_PACKAGE_VERSION#v}"
PACKAGE_VERSION="${PACKAGE_VERSION#V}"
RPM_RELEASE="${RPM_RELEASE:-1}"
REMOTE_PATH="${REMOTE_PATH:-/tmp}"
ADMIN_BUILD="${ADMIN_BUILD:-1}"
FORCE_LOG_LEVEL="${FORCE_LOG_LEVEL:-}"

RPM_FILE="${PACKAGE_NAME}-${PACKAGE_VERSION}-${RPM_RELEASE}.x86_64.rpm"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}$*${NC}"; }
log_ok() { echo -e "${GREEN}$*${NC}"; }
log_err() { echo -e "${RED}$*${NC}"; }

echo -e "${GREEN}Starting RPM deployment of ${PACKAGE_NAME} version ${PACKAGE_VERSION}${NC}"
echo -e "${YELLOW}Remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}${NC}"
if [[ -n "${FORCE_LOG_LEVEL}" ]]; then
  echo -e "${YELLOW}Force runtime log level: ${FORCE_LOG_LEVEL}${NC}"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$ADMIN_BUILD" = "1" ]]; then
  log_info "Building admin UI assets..."
  (
    cd "${ROOT_DIR}/admin"
    if [ -f package-lock.json ]; then
      npm ci
    else
      npm install
    fi
    npm run build
  )
fi

# Step 1: Build package
log_info "Building RPM package..."
make package-rpm-amd64 VERSION="${PACKAGE_VERSION}"

if [[ ! -f "release/${RPM_FILE}" ]]; then
  log_err "Expected package not found: release/${RPM_FILE}"
  exit 1
fi

# Step 2: Copy package to remote server
log_info "Copying package to remote server..."
scp "release/${RPM_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

# Step 3: Install/update package on remote server
log_info "Installing/updating package on remote server..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" <<EOF
set -euo pipefail
PKG_PATH="${REMOTE_PATH}/${RPM_FILE}"
FORCE_LOG_LEVEL="${FORCE_LOG_LEVEL}"

if command -v dnf >/dev/null 2>&1; then
  if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    sudo dnf reinstall -y "\${PKG_PATH}" || sudo dnf install -y "\${PKG_PATH}"
  else
    sudo dnf install -y "\${PKG_PATH}"
  fi
elif command -v yum >/dev/null 2>&1; then
  if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    sudo yum reinstall -y "\${PKG_PATH}" || sudo yum install -y "\${PKG_PATH}"
  else
    sudo yum install -y "\${PKG_PATH}"
  fi
else
  sudo rpm -Uvh --replacepkgs "\${PKG_PATH}"
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "WARNING: sqlite3 is not installed on target host." >&2
  echo "Local admin login (/api/auth/login) will return 401 until sqlite3 is installed." >&2
  echo "Install with: sudo dnf install -y sqlite" >&2
fi

PACKAGE_ROOT="/opt/${PACKAGE_NAME}"
START_ERL_FILE="\${PACKAGE_ROOT}/releases/start_erl.data"
if [ ! -f "\${START_ERL_FILE}" ]; then
  echo "ERROR: start_erl.data not found at \${START_ERL_FILE}" >&2
  exit 1
fi

ERTS_VSN="\$(awk '{print \$1}' "\${START_ERL_FILE}" | head -n1)"
REL_VSN="\$(awk '{print \$2}' "\${START_ERL_FILE}" | head -n1)"

if [ -z "\${ERTS_VSN}" ] || [ -z "\${REL_VSN}" ]; then
  echo "ERROR: invalid start_erl.data content in \${START_ERL_FILE}" >&2
  exit 1
fi

REL_DIR="\${PACKAGE_ROOT}/releases/\${REL_VSN}"
if [ -f "\${REL_DIR}/pertisk_eproxy.boot" ]; then
  BOOT_BASE="pertisk_eproxy"
elif [ -f "\${REL_DIR}/start.boot" ]; then
  BOOT_BASE="start"
else
  echo "ERROR: no boot file in \${REL_DIR}" >&2
  ls -la "\${REL_DIR}" >&2 || true
  exit 1
fi

echo "Refreshing systemd override with release \${REL_VSN} (erts \${ERTS_VSN}, boot \${BOOT_BASE})..." >&2
DROPIN_DIR="/etc/systemd/system/${PACKAGE_NAME}.service.d"
MANAGED_DROPIN="\${DROPIN_DIR}/10-execstart-compat.conf"
LOG_LEVEL_DROPIN="\${DROPIN_DIR}/10-log-level.conf"
sudo mkdir -p "\${DROPIN_DIR}"

# Remove stale release-pinned drop-ins from previous deploy logic.
for conf in \$(sudo find "\${DROPIN_DIR}" -maxdepth 1 -type f -name '*.conf' 2>/dev/null || true); do
  if [ "\${conf}" = "\${MANAGED_DROPIN}" ]; then
    continue
  fi
  if sudo grep -Eq 'ExecStart=.*/pertisk_eproxy.*-args_file .*/releases/.*/vm.args' "\${conf}"; then
    echo "Removing stale drop-in: \${conf}" >&2
    sudo rm -f "\${conf}"
  fi
done

sudo tee "\${MANAGED_DROPIN}" >/dev/null <<UNITEOF
[Service]
Environment=ROOTDIR=/opt/${PACKAGE_NAME}
Environment=BINDIR=\${PACKAGE_ROOT}/erts-\${ERTS_VSN}/bin
Environment=EMU=beam
Environment=PROGNAME=erl
Environment=LD_LIBRARY_PATH=\${PACKAGE_ROOT}/lib/runtime:\${PACKAGE_ROOT}/lib/openssl
ExecStart=
ExecStart=\${PACKAGE_ROOT}/erts-\${ERTS_VSN}/bin/erlexec -noinput +Bd -boot \${PACKAGE_ROOT}/releases/\${REL_VSN}/\${BOOT_BASE} -mode embedded -boot_var SYSTEM_LIB_DIR \${PACKAGE_ROOT}/lib -config \${PACKAGE_ROOT}/releases/\${REL_VSN}/sys.config -args_file \${PACKAGE_ROOT}/releases/\${REL_VSN}/vm.args -- foreground
UNITEOF

if [ -n "\${FORCE_LOG_LEVEL}" ]; then
  sudo tee "\${LOG_LEVEL_DROPIN}" >/dev/null <<LOGEOF
[Service]
Environment=PERTISK_LOG_LEVEL=\${FORCE_LOG_LEVEL}
LOGEOF
else
  sudo rm -f "\${LOG_LEVEL_DROPIN}"
fi

sudo systemctl daemon-reload
sudo systemctl enable "${PACKAGE_NAME}" --now
sudo systemctl reset-failed "${PACKAGE_NAME}" || true
sudo systemctl restart "${PACKAGE_NAME}"

STALE_EXECSTART_LINES="\$(sudo systemctl cat "${PACKAGE_NAME}" | grep '^ExecStart=' | grep '/releases/' | grep -v "/releases/\${REL_VSN}/" || true)"
if [ -n "\${STALE_EXECSTART_LINES}" ]; then
  echo "ERROR: stale release-pinned ExecStart entries still active:" >&2
  echo "\${STALE_EXECSTART_LINES}" >&2
  exit 1
fi

if sudo systemctl cat "${PACKAGE_NAME}" | grep -Eq '^ExecStart=.*/bin/pertisk_eproxy foreground$'; then
  echo "ERROR: wrapper ExecStart is still active after compatibility override." >&2
  echo "Run: sudo systemctl cat ${PACKAGE_NAME}" >&2
  exit 1
fi

sudo systemctl is-active --quiet "${PACKAGE_NAME}"
echo "Service status:"
sudo systemctl status "${PACKAGE_NAME}" --no-pager
EOF

log_ok "RPM deployment completed successfully!"
