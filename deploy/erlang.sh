#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-0.5.47}"
NAMESPACE="${NAMESPACE:-pertisk-eproxy}"
RELEASE_NAME="${RELEASE_NAME:-pertisk-eproxy}"
CHART_PATH="${CHART_PATH:-./deploy/helm/pertisk-eproxy}"
ADMIN_HOST="${ADMIN_HOST:-admin.erlang.pertisk.com}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
CPU_REQUEST="${CPU_REQUEST:-1000m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-512Mi}"
CPU_LIMIT="${CPU_LIMIT:-2000m}"
MEMORY_LIMIT="${MEMORY_LIMIT:-1Gi}"
PROXY_ACCESS_LOG="${PROXY_ACCESS_LOG:-false}"
HEALTH_ACCESS_LOG="${HEALTH_ACCESS_LOG:-false}"
HEALTH_ACCESS_LOG_SAMPLE="${HEALTH_ACCESS_LOG_SAMPLE:-0}"
# HTTP/3 (QUIC) needs one pod or node-local UDP; 3 replicas + cloud LB breaks QUIC and tanks k6 TPS.
REPLICA_COUNT="${REPLICA_COUNT:-3}"

echo "Deploying ${RELEASE_NAME} version ${VERSION} to namespace ${NAMESPACE} (replicas=${REPLICA_COUNT})"

make docker-ingress-multi VERSION="$VERSION"

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout "$HELM_TIMEOUT" \
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
  --set controller.config.log_level=info \
  --set controller.config.h3_quic_pool_size=32 \
  --set resources.requests.cpu="$CPU_REQUEST" \
  --set resources.requests.memory="$MEMORY_REQUEST" \
  --set resources.limits.cpu="$CPU_LIMIT" \
  --set resources.limits.memory="$MEMORY_LIMIT"