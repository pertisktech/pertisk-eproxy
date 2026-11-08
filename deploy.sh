#!/usr/bin/env bash
# Thin wrapper — prefer ./scripts/build-deploy.sh
#
#   VERSION=0.2.16 DEPLOY_HOST=root@10.1.1.148 ./scripts/build-deploy.sh
#   VERSION=0.2.16 DEPLOY_HOST=root@10.1.1.148 ./deploy.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${ROOT_DIR}/scripts/build-deploy.sh" "$@"
