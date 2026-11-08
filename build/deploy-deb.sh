#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=deploy-common.sh
source "${ROOT_DIR}/build/deploy-common.sh"
resolve_deploy_host

# Configuration (override via env vars or first CLI arg for version)
# Prefer DEPLOY_HOST=user@host; REMOTE_HOST / REMOTE_USER still work.
REMOTE_HOST="${REMOTE_HOST:?Set DEPLOY_HOST=user@host or REMOTE_HOST}"
REMOTE_USER="${REMOTE_USER:-root}"
PACKAGE_NAME="${PACKAGE_NAME:-pertisk-eproxy}"
RAW_PACKAGE_VERSION="${1:-${PACKAGE_VERSION:-${VERSION:-0.5.47}}}"
PACKAGE_VERSION="${RAW_PACKAGE_VERSION#v}"
PACKAGE_VERSION="${PACKAGE_VERSION#V}"
REMOTE_PATH="${REMOTE_PATH:-/tmp}"
ADMIN_BUILD="${ADMIN_BUILD:-1}"
PACKAGE_BUILD="${PACKAGE_BUILD:-1}"
FORCE_LOG_LEVEL="${FORCE_LOG_LEVEL:-warn}"
FORCE_PROXY_ACCESS_LOG="${FORCE_PROXY_ACCESS_LOG:-false}"
FORCE_MANAGEMENT_PORT="${FORCE_MANAGEMENT_PORT:-9081}"
# Host Erlang toolchains can crash in beam_asm on some systems; default to
# Dockerized Linux/amd64 release build for deb packaging.
RELEASE_BUILD_FORCE_DOCKER="${RELEASE_BUILD_FORCE_DOCKER:-1}"
RELEASE_BUILD_PLATFORM="${RELEASE_BUILD_PLATFORM:-linux/amd64}"

DEB_FILE="${PACKAGE_NAME}_${PACKAGE_VERSION}_amd64.deb"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}$*${NC}"; }
log_ok() { echo -e "${GREEN}$*${NC}"; }
log_err() { echo -e "${RED}$*${NC}"; }

echo -e "${GREEN}Starting Debian deployment of ${PACKAGE_NAME} version ${PACKAGE_VERSION}${NC}"
echo -e "${YELLOW}Remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}${NC}"
if [[ -n "${FORCE_LOG_LEVEL}" ]]; then
	echo -e "${YELLOW}Force runtime log level: ${FORCE_LOG_LEVEL}${NC}"
fi
echo -e "${YELLOW}Force proxy access log: ${FORCE_PROXY_ACCESS_LOG}${NC}"
if [[ -n "${FORCE_MANAGEMENT_PORT}" ]]; then
	echo -e "${YELLOW}Force management port: ${FORCE_MANAGEMENT_PORT}${NC}"
fi

cd "$ROOT_DIR"

if [[ "$PACKAGE_BUILD" = "1" ]]; then
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

	log_info "Building Debian package..."
	RELEASE_BUILD_FORCE_DOCKER="${RELEASE_BUILD_FORCE_DOCKER}" \
	RELEASE_BUILD_PLATFORM="${RELEASE_BUILD_PLATFORM}" \
	make package-deb-amd64 VERSION="${PACKAGE_VERSION}"
else
	log_info "Skipping package build (PACKAGE_BUILD=0)"
fi

if [[ ! -f "release/${DEB_FILE}" ]]; then
	log_err "Expected package not found: release/${DEB_FILE}"
	exit 1
fi

# Step 2: Copy package to remote server
log_info "Copying package to remote server..."
scp "release/${DEB_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

# Step 3: Install/update package on remote server
log_info "Installing/updating package on remote server..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" <<EOF
set -euo pipefail
PKG_PATH="${REMOTE_PATH}/${DEB_FILE}"
FORCE_LOG_LEVEL="${FORCE_LOG_LEVEL}"
FORCE_PROXY_ACCESS_LOG="${FORCE_PROXY_ACCESS_LOG}"
FORCE_MANAGEMENT_PORT="${FORCE_MANAGEMENT_PORT}"

sudo dpkg -i "\${PKG_PATH}"
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -f install -y

if ! command -v sqlite3 >/dev/null 2>&1; then
	echo "WARNING: sqlite3 is not installed on target host." >&2
	echo "Local admin login (/api/auth/login) will return 401 until sqlite3 is installed." >&2
	echo "Install with: sudo apt-get install -y sqlite3" >&2
fi

sudo systemctl enable "${PACKAGE_NAME}" --now
if [ -n "${FORCE_LOG_LEVEL}" ]; then
	sudo mkdir -p "/etc/systemd/system/${PACKAGE_NAME}.service.d"
	sudo tee "/etc/systemd/system/${PACKAGE_NAME}.service.d/10-log-level.conf" >/dev/null <<EOC
[Service]
Environment=PERTISK_LOG_LEVEL=${FORCE_LOG_LEVEL}
EOC
else
	sudo rm -f "/etc/systemd/system/${PACKAGE_NAME}.service.d/10-log-level.conf"
fi

if [ -n "${FORCE_PROXY_ACCESS_LOG}" ]; then
	sudo mkdir -p "/etc/systemd/system/${PACKAGE_NAME}.service.d"
	sudo tee "/etc/systemd/system/${PACKAGE_NAME}.service.d/11-proxy-access-log.conf" >/dev/null <<EOC
[Service]
Environment=PERTISK_PROXY_ACCESS_LOG=${FORCE_PROXY_ACCESS_LOG}
EOC
else
	sudo rm -f "/etc/systemd/system/${PACKAGE_NAME}.service.d/11-proxy-access-log.conf"
fi

PACKAGE_ROOT="/opt/${PACKAGE_NAME}"
if [ -f "\${PACKAGE_ROOT}/config/proxy.json" ]; then
	sudo FORCE_MANAGEMENT_PORT="\${FORCE_MANAGEMENT_PORT}" python3 - <<"PY" || true
import json, os
path = "/opt/pertisk-eproxy/config/proxy.json"
with open(path) as f:
    c = json.load(f)
c["quic_enabled"] = True
c["h3_api_gateway_enabled"] = True
c["h3_probe_enabled"] = False
port = os.environ.get("FORCE_MANAGEMENT_PORT", "").strip()
if port:
    c["management_port"] = int(port)
with open(path, "w") as f:
    json.dump(c, f, indent=4)
    f.write("\n")
msg = "proxy.json: quic_enabled=true h3_api_gateway_enabled=true"
if port:
    msg += f" management_port={port}"
print(msg)
PY
fi

if [ -n "\${FORCE_MANAGEMENT_PORT}" ] && command -v ufw >/dev/null 2>&1; then
	sudo ufw allow "\${FORCE_MANAGEMENT_PORT}/tcp" || true
fi

sudo systemctl daemon-reload
sudo systemctl restart "${PACKAGE_NAME}"
sudo systemctl is-active --quiet "${PACKAGE_NAME}"
echo "Service status:"
sudo systemctl status "${PACKAGE_NAME}" --no-pager
EOF

log_ok "Debian deployment completed successfully!"
