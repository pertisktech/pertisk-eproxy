#!/usr/bin/env bash
# Build packages, then deploy to DEPLOY_HOST (RPM or DEB).
#
# Usage (from repo root):
#   VERSION=0.2.16 DEPLOY_HOST=root@10.1.1.148 ./scripts/build-deploy.sh
#   VERSION=0.2.16 DEPLOY_HOST=root@host DEPLOY_PKG=deb ./scripts/build-deploy.sh
#   VERSION=0.2.16 DEPLOY_HOST=root@host BUILD_PKG=all ./scripts/build-deploy.sh
#
# Defaults:
#   VERSION     — git describe, or 0.1.0
#   DEPLOY_PKG  — auto (detect rpm/deb on remote), or rpm|deb
#   BUILD_PKG   — same as DEPLOY_PKG (or all)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../build/deploy-common.sh
source "${REPO_ROOT}/build/deploy-common.sh"

export VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo '0.1.0')}"
VERSION="${VERSION#v}"
DEPLOY_HOST="${DEPLOY_HOST:?Set DEPLOY_HOST, e.g. root@10.1.1.148}"
export DEPLOY_HOST
resolve_deploy_host

DEPLOY_PKG="${DEPLOY_PKG:-auto}"
if [ "$DEPLOY_PKG" = "auto" ]; then
  DEPLOY_PKG="$(detect_remote_pkg_kind "$(deploy_ssh_target)" "${DEPLOY_SSH_OPTS:-}")"
  echo "==> Detected remote package kind: ${DEPLOY_PKG}"
fi
export DEPLOY_PKG

BUILD_PKG="${BUILD_PKG:-$DEPLOY_PKG}"
export BUILD_PKG

# Local package deploys use management UI on 9081 by default (override or clear).
export FORCE_MANAGEMENT_PORT="${FORCE_MANAGEMENT_PORT:-9081}"

echo "==> Build+deploy pertisk-eproxy v${VERSION} (${BUILD_PKG} → ${DEPLOY_HOST} as ${DEPLOY_PKG}, management=${FORCE_MANAGEMENT_PORT})"

"${SCRIPT_DIR}/build.sh"
PACKAGE_BUILD=0 "${SCRIPT_DIR}/deploy.sh"
