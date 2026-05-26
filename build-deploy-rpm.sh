#!/usr/bin/env bash

set -euo pipefail

# Configuration (override via env vars or first CLI arg for version)
REMOTE_HOST="${REMOTE_HOST:-135.181.197.40}"
REMOTE_USER="${REMOTE_USER:-root}"
PACKAGE_NAME="${PACKAGE_NAME:-pertisk-eproxy}"
PACKAGE_VERSION="${1:-${PACKAGE_VERSION:-0.3.21}}"
RPM_RELEASE="${RPM_RELEASE:-1}"
REMOTE_PATH="${REMOTE_PATH:-/tmp}"

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

# Step 1: Build package
log_info "Building RPM package..."
make package-rpm-amd64 PACKAGE_VERSION="${PACKAGE_VERSION}"

# Step 2: Copy package to remote server
log_info "Copying package to remote server..."
scp "release/${RPM_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

# Step 3: Install/update package on remote server
log_info "Installing/updating package on remote server..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" <<EOF
set -euo pipefail
PKG_PATH="${REMOTE_PATH}/${RPM_FILE}"

if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y "\${PKG_PATH}"
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y "\${PKG_PATH}"
else
  sudo rpm -Uvh --replacepkgs "\${PKG_PATH}"
fi

sudo systemctl enable "${PACKAGE_NAME}" --now
sudo systemctl restart "${PACKAGE_NAME}"
echo "Service status:"
sudo systemctl status "${PACKAGE_NAME}" --no-pager
EOF

log_ok "RPM deployment completed successfully!"
