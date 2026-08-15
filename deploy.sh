#!/usr/bin/env bash
# Example local RPM deploy. Override host/user; do not commit real targets.
set -euo pipefail
: "${REMOTE_HOST:?Set REMOTE_HOST to the target host}"
REMOTE_USER="${REMOTE_USER:-root}"
VERSION="${VERSION:-0.1.20}"
VERSION="$VERSION" REMOTE_HOST="$REMOTE_HOST" REMOTE_USER="$REMOTE_USER" ./build/deploy-rpm.sh
