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
HARBOR_REGISTRY="${HARBOR_REGISTRY:-registry.tools.thaidevops.co}"
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

# BuildKit's direct registry PUT is rejected by registry.tools.thaidevops.co
# (400 digest_invalid). Export a docker archive, then push with the engine client.
push_via_docker() {
  local dockerfile="$1" ptag="$2" platform="$3"
  local tmp load_out image_ref
  tmp="$(mktemp -d)"
  echo "==> buildx ${platform} -> docker archive -> ${ptag}"
  docker buildx build --builder "$BUILDER" \
    "${build_args[@]}" \
    --platform "$platform" \
    --provenance=false --sbom=false \
    --output "type=docker,dest=${tmp}/image.tar" \
    -f "$dockerfile" .
  load_out="$(docker load -i "${tmp}/image.tar")"
  echo "$load_out"
  rm -rf "$tmp"
  image_ref="$(printf '%s\n' "$load_out" | sed -n 's/^Loaded image: //p' | tail -1)"
  if [ -z "$image_ref" ]; then
    image_ref="$(printf '%s\n' "$load_out" | sed -n 's/^Loaded image ID: //p' | tail -1)"
  fi
  if [ -z "$image_ref" ]; then
    echo "docker load did not report an image for ${ptag}" >&2
    return 1
  fi
  docker tag "$image_ref" "$ptag"
  docker push "$ptag"
}

build_image_multi() {
  local dockerfile="$1" tag_base="$2"
  local tag="${tag_base}:${VERSION}" latest="${tag_base}:latest"

  if [ "$BUILD_SEQUENTIAL" = "1" ]; then
    local srcs="" p suffix ptag
    for p in $(echo "$PLATFORMS" | tr ',' ' '); do
      suffix="${p#linux/}"
      ptag="${tag_base}:${VERSION}-${suffix}"
      push_via_docker "$dockerfile" "$ptag" "$p"
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
      --output "type=image,push=true,oci-mediatypes=false,compression=gzip,force-compression=true" \
      -f "$dockerfile" -t "$tag" -t "$latest" .
  fi
}

ensure_builder
build_image_multi "$DOCKERFILE_PROXY" "$PROXY_IMAGE"
build_image_multi "$DOCKERFILE_INGRESS" "$INGRESS_IMAGE"
