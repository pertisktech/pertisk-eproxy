#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./build-docker-harbor.sh [VERSION]
#   VERSION=1.2.3 IMAGE=harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy ./build-docker-harbor.sh
VERSION="${VERSION:-${1:-x.x.x}}"
IMAGE="${IMAGE:-${HARBOR_IMAGE:-harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy}}"
PLATFORMS="${INGRESS_BUILD_PLATFORMS:-linux/amd64,linux/arm64}"
PROVENANCE="${INGRESS_BUILD_PROVENANCE:-false}"
SBOM="${INGRESS_BUILD_SBOM:-false}"

printf 'Building and pushing multi-arch eProxy image\n'
printf 'VERSION=%s IMAGE=%s PLATFORMS=%s PROVENANCE=%s SBOM=%s\n' "$VERSION" "$IMAGE" "$PLATFORMS" "$PROVENANCE" "$SBOM"

make docker-eproxy-multi \
	VERSION="$VERSION" \
	IMAGE="$IMAGE" \
	INGRESS_BUILD_PLATFORMS="$PLATFORMS" \
	INGRESS_BUILD_PROVENANCE="$PROVENANCE" \
	INGRESS_BUILD_SBOM="$SBOM"
