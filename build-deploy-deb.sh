#!/usr/bin/env bash

set -euo pipefail

# Configuration (override via env vars or first CLI arg for version)
REMOTE_HOST="${REMOTE_HOST:-10.1.1.8}"
REMOTE_USER="${REMOTE_USER:-root}"
PACKAGE_NAME="${PACKAGE_NAME:-pertisk-eproxy}"
PACKAGE_VERSION="${1:-${PACKAGE_VERSION:-0.4.43}}"
REMOTE_PATH="${REMOTE_PATH:-/tmp}"
ADMIN_BUILD="${ADMIN_BUILD:-1}"
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
log_info "Building Debian package..."
RELEASE_BUILD_FORCE_DOCKER="${RELEASE_BUILD_FORCE_DOCKER}" \
RELEASE_BUILD_PLATFORM="${RELEASE_BUILD_PLATFORM}" \
make package-deb-amd64 VERSION="${PACKAGE_VERSION}"

# Step 2: Copy package to remote server
log_info "Copying package to remote server..."
scp "release/${DEB_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

# Step 3: Install/update package on remote server
log_info "Installing/updating package on remote server..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" <<EOF
set -euo pipefail
PKG_PATH="${REMOTE_PATH}/${DEB_FILE}"

sudo dpkg -i "\${PKG_PATH}"
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -f install -y
sudo systemctl enable "${PACKAGE_NAME}" --now
sudo systemctl restart "${PACKAGE_NAME}"
sudo systemctl is-active --quiet "${PACKAGE_NAME}"
echo "Service status:"
sudo systemctl status "${PACKAGE_NAME}" --no-pager
EOF

log_ok "Debian deployment completed successfully!"
