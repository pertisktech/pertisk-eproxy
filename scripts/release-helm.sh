#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release-helm.sh [options]

Options:
  --chart-dir DIR    Helm chart directory (default: deploy/helm/pertisk-eproxy)
  --output-dir DIR   Output directory for .tgz package (default: release/helm)
  --version VER      Chart/app version to package (default: read from Chart.yaml)
  --oci-repo REPO    OCI repo, e.g. oci://harbor.example.com/pertisksoft/helm
  --push             Push package to OCI repo using helm push
  -h, --help         Show this help

Examples:
  scripts/release-helm.sh --version 0.4.30
  scripts/release-helm.sh --version 0.4.30 --push --oci-repo oci://harbor.example.com/pertisksoft/helm
EOF
}

CHART_DIR="deploy/helm/pertisk-eproxy"
OUTPUT_DIR="release/helm"
VERSION=""
OCI_REPO=""
DO_PUSH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart-dir)
      CHART_DIR="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --oci-repo)
      OCI_REPO="$2"
      shift 2
      ;;
    --push)
      DO_PUSH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required but not found in PATH" >&2
  exit 1
fi

if [[ ! -f "$CHART_DIR/Chart.yaml" ]]; then
  echo "Chart.yaml not found in chart directory: $CHART_DIR" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(awk '$1 == "version:" {print $2; exit}' "$CHART_DIR/Chart.yaml")"
fi

if [[ -z "$VERSION" ]]; then
  echo "Unable to determine chart version. Pass --version." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Linting chart: $CHART_DIR"
helm lint "$CHART_DIR"

echo "Packaging chart version $VERSION"
helm package "$CHART_DIR" \
  --version "$VERSION" \
  --app-version "$VERSION" \
  --destination "$OUTPUT_DIR"

PKG_PATH="$OUTPUT_DIR/pertisk-eproxy-$VERSION.tgz"
if [[ ! -f "$PKG_PATH" ]]; then
  echo "Expected package not found: $PKG_PATH" >&2
  exit 1
fi

echo "Chart package created: $PKG_PATH"

if [[ "$DO_PUSH" -eq 1 ]]; then
  if [[ -z "$OCI_REPO" ]]; then
    echo "--push requires --oci-repo" >&2
    exit 1
  fi

  echo "Pushing chart to OCI repo: $OCI_REPO"
  helm push "$PKG_PATH" "$OCI_REPO"
  echo "Chart uploaded: $OCI_REPO/pertisk-eproxy:$VERSION"
fi
