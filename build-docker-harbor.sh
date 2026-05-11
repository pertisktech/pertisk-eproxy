#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./build-docker-harbor.sh [VERSION]
#   VERSION=v1.0.0 IMAGE=harbor.example.com/team/pertisk-eproxy ./build-docker-harbor.sh
VERSION="${VERSION:-${1:-v1.0.0}}"
IMAGE="${IMAGE:-${HARBOR_IMAGE:-harbor.example.com/pertisk-eproxy}}"
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
