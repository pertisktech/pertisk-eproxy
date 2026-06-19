#!/usr/bin/env bash
set -euo pipefail

# Builds and pushes multi-arch proxy + ingress images to Harbor (no make required).
#
# Usage:
#   VERSION=0.5.10 ./build/docker-harbor.sh
#   ./build/docker-harbor.sh 0.5.10

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

raw_version="${VERSION:-${1:-x.x.x}}"
VERSION="${raw_version#v}"
PLATFORMS="${BUILD_PLATFORMS:-linux/amd64,linux/arm64}"
PROVENANCE="${BUILD_PROVENANCE:-false}"
SBOM="${BUILD_SBOM:-false}"
BUILD_SEQUENTIAL="${BUILD_SEQUENTIAL:-${CI:+1}}"
BUILDER="${BUILDX_MULTI_BUILDER:-pertisk-multiarch}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.tools.thaidevops.co}"
PROXY_IMAGE="${HARBOR_PROXY_IMAGE:-${HARBOR_REGISTRY}/pertisksoft/pertisk-eproxy/proxy}"
INGRESS_IMAGE="${HARBOR_INGRESS_IMAGE:-${HARBOR_REGISTRY}/pertisksoft/pertisk-eproxy/ingress}"
FRONTEND_BUILD_ID="${FRONTEND_BUILD_ID:-${GITHUB_RUN_ID:-dev}}"
DOCKERFILE_PROXY="${DOCKERFILE:-docker/Dockerfile.proxy}"
DOCKERFILE_INGRESS="${DOCKERFILE_INGRESS:-docker/Dockerfile.ingress}"

echo "Building and pushing multi-arch images"
echo "VERSION=${VERSION} PLATFORMS=${PLATFORMS} PROVENANCE=${PROVENANCE} SBOM=${SBOM} BUILD_SEQUENTIAL=${BUILD_SEQUENTIAL:-0}"

ensure_builder() {
  if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    docker buildx create --name "$BUILDER" --driver docker-container --driver-opt network=host >/dev/null
  fi
  docker buildx inspect --bootstrap "$BUILDER" >/dev/null
}

build_args=(--build-arg "VERSION=${VERSION}" --build-arg "FRONTEND_BUILD_ID=${FRONTEND_BUILD_ID}")

build_image_multi() {
  local dockerfile="$1" tag_base="$2"
  local tag="${tag_base}:${VERSION}" latest="${tag_base}:latest"

  if [ "$BUILD_SEQUENTIAL" = "1" ]; then
    local srcs="" p suffix ptag
    for p in $(echo "$PLATFORMS" | tr ',' ' '); do
      suffix="${p#linux/}"
      ptag="${tag_base}:${VERSION}-${suffix}"
      echo "==> docker buildx (sequential) platform=${p} tag=${ptag}"
      docker buildx build --builder "$BUILDER" \
        "${build_args[@]}" \
        --platform "$p" \
        --provenance="$PROVENANCE" --sbom="$SBOM" \
        --push -f "$dockerfile" -t "$ptag" .
      srcs="${srcs} ${ptag}"
    done
    echo "==> docker buildx imagetools create ${tag}"
    # shellcheck disable=SC2086
    docker buildx imagetools create -t "$tag" $srcs
    # shellcheck disable=SC2086
    docker buildx imagetools create -t "$latest" $srcs
  else
    docker buildx build --builder "$BUILDER" \
      "${build_args[@]}" \
      --platform "$PLATFORMS" \
      --provenance="$PROVENANCE" --sbom="$SBOM" \
      --push -f "$dockerfile" -t "$tag" -t "$latest" .
  fi
}

ensure_builder
build_image_multi "$DOCKERFILE_PROXY" "$PROXY_IMAGE"
build_image_multi "$DOCKERFILE_INGRESS" "$INGRESS_IMAGE"
