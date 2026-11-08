#!/usr/bin/env bash
# Deploy pre-built pertisk-eproxy packages from release/.
# Run ./scripts/build.sh first (or set PACKAGE_BUILD=1 to build during deploy).
#
# Usage (from repo root):
#   DEPLOY_HOST=user@host ./scripts/deploy.sh
#   DEPLOY_HOST=user@host VERSION=0.2.16 PACKAGE_BUILD=1 ./scripts/deploy.sh
#   DEPLOY_HOST=user@host DEPLOY_PKG=rpm ./scripts/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../build/deploy-common.sh
source "${REPO_ROOT}/build/deploy-common.sh"

export VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo '0.1.0')}"
VERSION="${VERSION#v}"
export PACKAGE_BUILD="${PACKAGE_BUILD:-0}"
DEPLOY_HOST="${DEPLOY_HOST:?Set DEPLOY_HOST, e.g. root@10.1.1.148}"
resolve_deploy_host

DEPLOY_PKG="${DEPLOY_PKG:-auto}"
if [ "$DEPLOY_PKG" = "auto" ]; then
  DEPLOY_PKG="$(detect_remote_pkg_kind "$(deploy_ssh_target)" "${DEPLOY_SSH_OPTS:-}")"
  echo "==> Detected remote package kind: ${DEPLOY_PKG}"
fi

echo "==> Deploying v${VERSION} (${DEPLOY_PKG}) to ${DEPLOY_HOST} (PACKAGE_BUILD=${PACKAGE_BUILD})"

case "$DEPLOY_PKG" in
  rpm)
    if [ "$PACKAGE_BUILD" = "1" ] || [ ! -f "release/pertisk-eproxy-${VERSION}-1.x86_64.rpm" ]; then
      make package-rpm-amd64 VERSION="$VERSION"
    fi
    make deploy-rpm DEPLOY_HOST="$DEPLOY_HOST" VERSION="$VERSION" PACKAGE_BUILD=0
    ;;
  deb)
    if [ "$PACKAGE_BUILD" = "1" ] || [ ! -f "release/pertisk-eproxy_${VERSION}_amd64.deb" ]; then
      make package-deb-amd64 VERSION="$VERSION"
    fi
    make deploy-deb DEPLOY_HOST="$DEPLOY_HOST" VERSION="$VERSION" PACKAGE_BUILD=0
    ;;
  *)
    echo "DEPLOY_PKG must be rpm, deb, or auto (got: $DEPLOY_PKG)" >&2
    exit 1
    ;;
esac

echo "==> Deploy complete."
