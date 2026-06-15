#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-}"
FRONTEND_BUILD_ID="${FRONTEND_BUILD_ID:-$(date +%s)}"
FORCE_DEPLOY="${FORCE_DEPLOY:-false}"
NAMESPACE="${NAMESPACE:-pertisk-eproxy}"
RELEASE_NAME="${RELEASE_NAME:-pertisk-eproxy}"
CHART_PATH="${CHART_PATH:-./deploy/helm/pertisk-eproxy}"
ADMIN_HOST="${ADMIN_HOST:-admin.erlang.pertisk.com}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-10m}"
VERIFY_ADMIN_UI="${VERIFY_ADMIN_UI:-true}"
CPU_REQUEST="${CPU_REQUEST:-1000m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-512Mi}"
CPU_LIMIT="${CPU_LIMIT:-2000m}"
MEMORY_LIMIT="${MEMORY_LIMIT:-1Gi}"
PROXY_ACCESS_LOG="${PROXY_ACCESS_LOG:-false}"
HEALTH_ACCESS_LOG="${HEALTH_ACCESS_LOG:-false}"
HEALTH_ACCESS_LOG_SAMPLE="${HEALTH_ACCESS_LOG_SAMPLE:-0}"
METRICS_ENABLED="${METRICS_ENABLED:-true}"
SERVICEMONITOR_ENABLED="${SERVICEMONITOR_ENABLED:-true}"
SERVICEMONITOR_RELEASE_LABEL="${SERVICEMONITOR_RELEASE_LABEL:-kube-prometheus-stack}"
# HTTP/3 (QUIC) needs one pod or node-local UDP; 3 replicas + cloud LB breaks QUIC and tanks k6 TPS.
REPLICA_COUNT="${REPLICA_COUNT:-3}"

if [[ -z "$VERSION" ]]; then
  echo "ERROR: VERSION is required (example: VERSION=0.5.61 ./deploy/erlang.sh)" >&2
  exit 2
fi

DOCKER_NO_CACHE=false
if [[ "$FORCE_DEPLOY" == "true" ]]; then
  DOCKER_NO_CACHE=true
fi

echo "Deploying ${RELEASE_NAME} version ${VERSION} to namespace ${NAMESPACE} (replicas=${REPLICA_COUNT}, frontend_build_id=${FRONTEND_BUILD_ID}, force_deploy=${FORCE_DEPLOY})"

make docker-ingress-multi VERSION="$VERSION" FRONTEND_BUILD_ID="$FRONTEND_BUILD_ID" DOCKER_NO_CACHE="$DOCKER_NO_CACHE"

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout "$HELM_TIMEOUT" \
  --force-conflicts \
  --set image.tag="$VERSION" \
  --set image.pullPolicy=Always \
  --set auth.username=admin \
  --set auth.password='admin' \
  --set auth0.domain=dev-od6cfzs2tugxm53g.us.auth0.com \
  --set auth0.clientId=djuW8aR7VZQeS9SbW4ddnRCitgc6TiKO \
  --set auth0.audience=https://dev-od6cfzs2tugxm53g.us.auth0.com/api/v2/ \
  --set adminIngress.enabled=true \
  --set adminIngress.host="$ADMIN_HOST" \
  --set adminIngress.tlsSecretName=admin-erlang-tls \
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
  --set ingress.gatewayApiEnabled=true \
  --set gatewayClassResource.enabled=true

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

  MARKERS="$(curl -sk "${ADMIN_URL}${ASSET_PATH}" | grep -ao 'Config View\|show_all=1\|runtime_mode' | sort -u || true)"
  if [[ -z "$MARKERS" ]]; then
    echo "ERROR: Admin bundle verification failed (expected Settings markers missing)" >&2
    echo "       host=${ADMIN_HOST} asset=${ASSET_PATH}" >&2
    exit 4
  fi

  echo "Admin bundle markers found:"
  echo "$MARKERS"
fi