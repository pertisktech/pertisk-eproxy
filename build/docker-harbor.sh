#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./build/docker-harbor.sh [VERSION]
#   VERSION=0.5.10 ./build/docker-harbor.sh
#
# Builds and pushes multi-arch proxy + ingress images to Harbor.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-${1:-x.x.x}}"
PLATFORMS="${BUILD_PLATFORMS:-linux/amd64,linux/arm64}"
PROVENANCE="${BUILD_PROVENANCE:-false}"
SBOM="${BUILD_SBOM:-false}"
BUILD_SEQUENTIAL="${BUILD_SEQUENTIAL:-${CI:+1}}"

echo "Building and pushing multi-arch images"
echo "VERSION=${VERSION} PLATFORMS=${PLATFORMS} PROVENANCE=${PROVENANCE} SBOM=${SBOM} BUILD_SEQUENTIAL=${BUILD_SEQUENTIAL:-0}"

make docker-harbor-multi \
	VERSION="${VERSION}" \
	BUILD_PLATFORMS="${PLATFORMS}" \
	BUILD_PROVENANCE="${PROVENANCE}" \
	BUILD_SBOM="${SBOM}" \
	BUILD_SEQUENTIAL="${BUILD_SEQUENTIAL:-0}"
