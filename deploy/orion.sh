#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-}"
FRONTEND_BUILD_ID="${FRONTEND_BUILD_ID:-$(date +%s)}"
FORCE_DEPLOY="${FORCE_DEPLOY:-false}"
# Optional: DOCKER_NO_CACHE=true to bust BuildKit cache (heavy; can OOM Docker Desktop on multi-arch).
DOCKER_NO_CACHE="${DOCKER_NO_CACHE:-false}"
# Optional: BUILD_SEQUENTIAL=1 builds each platform separately (lower peak RAM on macOS).
BUILD_SEQUENTIAL="${BUILD_SEQUENTIAL:-}"
BUILD_PLATFORMS="${BUILD_PLATFORMS:-linux/amd64,linux/arm64}"
NAMESPACE="${NAMESPACE:-pertisk-eproxy}"
RELEASE_NAME="${RELEASE_NAME:-pertisk-eproxy}"
CHART_PATH="${CHART_PATH:-./deploy/helm/pertisk-eproxy}"
ADMIN_HOST="${ADMIN_HOST:-admin.example.com}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-10m}"
VERIFY_ADMIN_UI="${VERIFY_ADMIN_UI:-true}"
CPU_REQUEST="${CPU_REQUEST:-250m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-256Mi}"
CPU_LIMIT="${CPU_LIMIT:-1000m}"
MEMORY_LIMIT="${MEMORY_LIMIT:-1Gi}"
PROXY_ACCESS_LOG="${PROXY_ACCESS_LOG:-false}"
HEALTH_ACCESS_LOG="${HEALTH_ACCESS_LOG:-false}"
HEALTH_ACCESS_LOG_SAMPLE="${HEALTH_ACCESS_LOG_SAMPLE:-0}"
METRICS_ENABLED="${METRICS_ENABLED:-true}"
SERVICEMONITOR_ENABLED="${SERVICEMONITOR_ENABLED:-true}"
SERVICEMONITOR_RELEASE_LABEL="${SERVICEMONITOR_RELEASE_LABEL:-kube-prometheus-stack}"
GATEWAY_API_ENABLED="${GATEWAY_API_ENABLED:-true}"
GATEWAYCLASS_ENABLED="${GATEWAYCLASS_ENABLED:-true}"
# HTTP/3 (QUIC) needs one pod or node-local UDP; 3 replicas + cloud LB breaks QUIC and tanks k6 TPS.
REPLICA_COUNT="${REPLICA_COUNT:-3}"

if [[ -z "$VERSION" ]]; then
  echo "ERROR: VERSION is required (example: VERSION=0.5.61 ./deploy/orion.sh)" >&2
  exit 2
fi

if [[ -z "$BUILD_SEQUENTIAL" && "$(uname -s)" == "Darwin" ]]; then
  BUILD_SEQUENTIAL=1
fi

if [[ "$SERVICEMONITOR_ENABLED" == "true" ]]; then
  if ! kubectl api-resources --api-group=monitoring.coreos.com -o name 2>/dev/null | rg -q '^servicemonitors$'; then
    echo "ServiceMonitor CRD not found; disabling metrics.serviceMonitor.enabled for this deploy"
    SERVICEMONITOR_ENABLED=false
  fi
fi

if [[ "$GATEWAY_API_ENABLED" == "true" || "$GATEWAYCLASS_ENABLED" == "true" ]]; then
  if ! kubectl api-resources --api-group=gateway.networking.k8s.io -o name 2>/dev/null | rg -q '^gatewayclasses$'; then
    echo "Gateway API CRD not found; disabling ingress.gatewayApiEnabled and gatewayClassResource.enabled for this deploy"
    GATEWAY_API_ENABLED=false
    GATEWAYCLASS_ENABLED=false
  fi
fi

echo "Deploying ${RELEASE_NAME} version ${VERSION} to namespace ${NAMESPACE} (replicas=${REPLICA_COUNT}, frontend_build_id=${FRONTEND_BUILD_ID}, force_deploy=${FORCE_DEPLOY}, docker_no_cache=${DOCKER_NO_CACHE}, build_sequential=${BUILD_SEQUENTIAL}, platforms=${BUILD_PLATFORMS})"

make docker-ingress-multi \
  VERSION="$VERSION" \
  FRONTEND_BUILD_ID="$FRONTEND_BUILD_ID" \
  DOCKER_NO_CACHE="$DOCKER_NO_CACHE" \
  BUILD_SEQUENTIAL="$BUILD_SEQUENTIAL" \
  BUILD_PLATFORMS="$BUILD_PLATFORMS"

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout "$HELM_TIMEOUT" \
  --force-conflicts \
  --set image.tag="$VERSION" \
  --set image.pullPolicy=Always \
  --set auth.username=admin \
  --set auth.password="${AUTH_PASSWORD:?Set AUTH_PASSWORD}" \
  --set auth0.domain="${AUTH0_DOMAIN:-}" \
  --set auth0.clientId="${AUTH0_CLIENT_ID:-}" \
  --set auth0.audience="${AUTH0_AUDIENCE:-}" \
  --set adminIngress.enabled=true \
  --set adminIngress.host="$ADMIN_HOST" \
  --set adminIngress.tlsSecretName=admin-orion-tls \
  --set replicaCount="$REPLICA_COUNT" \
  --set autoscaling.enabled=true \
  --set service.externalTrafficPolicy=Cluster \
  --set controller.config.proxy_access_log="$PROXY_ACCESS_LOG" \
  --set controller.config.health_access_log="$HEALTH_ACCESS_LOG" \
  --set controller.config.health_access_log_sample="$HEALTH_ACCESS_LOG_SAMPLE" \
  --set metrics.enabled="$METRICS_ENABLED" \
  --set metrics.serviceMonitor.enabled="$SERVICEMONITOR_ENABLED" \
  --set metrics.serviceMonitor.labels.release="$SERVICEMONITOR_RELEASE_LABEL" \
  --set controller.config.h3_quic_pool_size=32 \
  --set resources.requests.cpu="$CPU_REQUEST" \
  --set resources.requests.memory="$MEMORY_REQUEST" \
  --set resources.limits.cpu="$CPU_LIMIT" \
  --set resources.limits.memory="$MEMORY_LIMIT" \
  --set ingress.gatewayApiEnabled="$GATEWAY_API_ENABLED" \
  --set gatewayClassResource.enabled="$GATEWAYCLASS_ENABLED"

echo "Forcing rollout restart to ensure fresh image is running..."
kubectl -n "$NAMESPACE" rollout restart "deployment/$RELEASE_NAME"
kubectl -n "$NAMESPACE" rollout status "deployment/$RELEASE_NAME" --timeout "$ROLLOUT_TIMEOUT"

if [[ "$VERIFY_ADMIN_UI" == "true" ]]; then
  ADMIN_URL="https://${ADMIN_HOST}"
  echo "Verifying live admin bundle from ${ADMIN_URL} ..."
  ASSET_PATH="$(curl -sk "$ADMIN_URL/" | sed -n 's/.*src="\([^\"]*assets[^\"]*\.js\)".*/\1/p' | head -n 1)"
  if [[ -z "$ASSET_PATH" ]]; then
    echo "ERROR: Could not extract admin JS asset path from ${ADMIN_URL}/" >&2
    exit 3
  fi

  # Normalize relative asset paths such as ./assets/*.js to avoid accidental host trailing-dot URLs.
  ASSET_URL="${ADMIN_URL}/${ASSET_PATH#./}"
  ASSET_CONTENT="$(curl -sk "$ASSET_URL")"

  if ! grep -Fq "$FRONTEND_BUILD_ID" <<< "$ASSET_CONTENT"; then
    echo "ERROR: Admin bundle verification failed (frontend build id missing in JS asset)" >&2
    echo "       host=${ADMIN_HOST} asset=${ASSET_PATH} expected_build_id=${FRONTEND_BUILD_ID}" >&2
    exit 4
  fi

  MARKERS="$(grep -ao 'Config View\|show_all=1\|runtime_mode' <<< "$ASSET_CONTENT" | sort -u || true)"
  if [[ -z "$MARKERS" ]]; then
    echo "WARN: Settings markers missing in minified bundle; build-id verification succeeded" >&2
  fi

  echo "Admin bundle verification passed: build_id=${FRONTEND_BUILD_ID} asset=${ASSET_PATH}"
  if [[ -n "$MARKERS" ]]; then
    echo "Admin bundle markers found:"
    echo "$MARKERS"
  fi
fi
