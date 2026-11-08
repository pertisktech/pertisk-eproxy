#!/usr/bin/env bash
# Build pertisk-eproxy packages (RPM and/or DEB, amd64).
#
# Usage (from repo root):
#   ./scripts/build.sh
#   VERSION=0.2.16 ./scripts/build.sh
#   BUILD_PKG=rpm VERSION=0.2.16 ./scripts/build.sh
#   BUILD_PKG=deb VERSION=0.2.16 ./scripts/build.sh
#   BUILD_PKG=all VERSION=0.2.16 ./scripts/build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

export VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo '0.1.0')}"
VERSION="${VERSION#v}"
BUILD_PKG="${BUILD_PKG:-all}"

mkdir -p release

echo "==> Building admin UI assets"
make admin-build

echo "==> Building pertisk-eproxy packages (${BUILD_PKG}) v${VERSION}"

case "$BUILD_PKG" in
  rpm)
    make package-rpm-amd64 VERSION="$VERSION"
    ;;
  deb)
    make package-deb-amd64 VERSION="$VERSION"
    ;;
  all)
    make package-rpm-amd64 VERSION="$VERSION"
    make package-deb-amd64 VERSION="$VERSION"
    ;;
  *)
    echo "BUILD_PKG must be rpm, deb, or all (got: $BUILD_PKG)" >&2
    exit 1
    ;;
esac

echo "==> Build complete. Artifacts in release/"
ls -la release/*"${VERSION}"* 2>/dev/null || ls -la release/ || true
