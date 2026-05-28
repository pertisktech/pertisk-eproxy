#!/usr/bin/env bash

set -euo pipefail

# Configuration (override via env vars or first CLI arg for version)
REMOTE_HOST="${REMOTE_HOST:-135.181.197.40}"
REMOTE_USER="${REMOTE_USER:-root}"
PACKAGE_NAME="${PACKAGE_NAME:-pertisk-eproxy}"
PACKAGE_VERSION="${1:-${PACKAGE_VERSION:-0.4.25}}"
RPM_RELEASE="${RPM_RELEASE:-1}"
REMOTE_PATH="${REMOTE_PATH:-/tmp}"
ADMIN_BUILD="${ADMIN_BUILD:-1}"
SMOKE_ENABLED="${SMOKE_ENABLED:-0}"
SMOKE_PATH="${SMOKE_PATH:-http://127.0.0.1:9080/docs}"
SMOKE_RETRIES="${SMOKE_RETRIES:-15}"
SMOKE_RETRY_DELAY="${SMOKE_RETRY_DELAY:-2}"
SMOKE_STRICT="${SMOKE_STRICT:-0}"

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
log_info "Building RPM package..."
make package-rpm-amd64 VERSION="${PACKAGE_VERSION}"

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
sudo systemctl is-active --quiet "${PACKAGE_NAME}"
echo "Service status:"
sudo systemctl status "${PACKAGE_NAME}" --no-pager

if [ "${SMOKE_ENABLED}" = "1" ]; then
  if command -v curl >/dev/null 2>&1; then
    echo "Smoke check: ${SMOKE_PATH}"
    ok=0
    i=1
    while [ "\${i}" -le "${SMOKE_RETRIES}" ]; do
      if curl -fsSL --max-time 10 "${SMOKE_PATH}" | grep -qi 'swagger-ui'; then
        ok=1
        break
      fi
      sleep "${SMOKE_RETRY_DELAY}"
      i=\$((i+1))
    done

    if [ "\${ok}" -ne 1 ]; then
      echo "WARNING: docs smoke check failed after ${SMOKE_RETRIES} attempts: ${SMOKE_PATH}" >&2
      if command -v ss >/dev/null 2>&1; then
        echo "Listener snapshot:" >&2
        ss -ltnp | grep -E '(:80|:443|:8080|:8443|:9080|:9443)' || true
      fi
      if [ "${SMOKE_STRICT}" = "1" ]; then
        exit 1
      fi
    fi
  else
    echo "WARNING: curl not found on remote; skipping docs smoke check" >&2
  fi
fi
EOF

log_ok "RPM deployment completed successfully!"
