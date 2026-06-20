#!/usr/bin/env bash
set -euo pipefail

# talos-255-prod-cluster — pertisk-eproxy (Erlang reverse proxy).
#
#   export KUBECONFIG=/Users/nat/.kube/talos-255-prod-cluster-kubeconfig.yaml
#   VERSION=0.5.98 ./deploy/h255.sh
#
# Gateway API admin UI (no Ingress for admin):
#   ADMIN_VIA_GATEWAY=true VERSION=0.5.98 ./deploy/h255.sh
#
# HTTP/3 benchmark (single replica):
#   REPLICA_COUNT=1 VERSION=0.5.98 ./deploy/h255.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-}"
FRONTEND_BUILD_ID="${FRONTEND_BUILD_ID:-$(date +%s)}"
DOCKER_NO_CACHE="${DOCKER_NO_CACHE:-false}"
BUILD_SEQUENTIAL="${BUILD_SEQUENTIAL:-}"
BUILD_PLATFORMS="${BUILD_PLATFORMS:-linux/amd64}"
NAMESPACE="${NAMESPACE:-pertisk-eproxy}"
RELEASE_NAME="${RELEASE_NAME:-pertisk-eproxy}"
CHART_PATH="${CHART_PATH:-./deploy/helm/pertisk-eproxy}"
H255_VALUES="${H255_VALUES:-./deploy/helm/pertisk-eproxy/h255/values.yaml}"
ADMIN_HOST="${ADMIN_HOST:-admin.erlang.pertisk.com}"
ADMIN_TLS_SECRET="${ADMIN_TLS_SECRET:-admin-erlang-tls}"
ADMIN_VIA_GATEWAY="${ADMIN_VIA_GATEWAY:-false}"
APPLY_ADMIN_GATEWAY="${APPLY_ADMIN_GATEWAY:-true}"
CLEANUP_LEGACY_GATEWAY_HOST="${CLEANUP_LEGACY_GATEWAY_HOST:-true}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-15m}"
VERIFY_ADMIN_UI="${VERIFY_ADMIN_UI:-false}"
REPLICA_COUNT="${REPLICA_COUNT:-3}"

AUTH0_DOMAIN="${AUTH0_DOMAIN:-dev-od6cfzs2tugxm53g.us.auth0.com}"
AUTH0_CLIENT_ID="${AUTH0_CLIENT_ID:-djuW8aR7VZQeS9SbW4ddnRCitgc6TiKO}"
AUTH0_AUDIENCE="${AUTH0_AUDIENCE:-https://dev-od6cfzs2tugxm53g.us.auth0.com/api/v2/}"

GATEWAY_API_ENABLED="${GATEWAY_API_ENABLED:-true}"
GATEWAYCLASS_ENABLED="${GATEWAYCLASS_ENABLED:-true}"

if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --always 2>/dev/null | sed 's/^v//' || true)"
fi
if [[ -z "$VERSION" ]]; then
  echo "ERROR: VERSION is required (example: VERSION=0.5.98 ./deploy/h255.sh)" >&2
  exit 2
fi

if [[ -z "$BUILD_SEQUENTIAL" && "$(uname -s)" == "Darwin" ]]; then
  BUILD_SEQUENTIAL=1
fi

if [[ "$GATEWAY_API_ENABLED" == "true" || "$GATEWAYCLASS_ENABLED" == "true" ]]; then
  if ! kubectl api-resources --api-group=gateway.networking.k8s.io -o name 2>/dev/null | rg -q '^gatewayclasses$'; then
    echo "Gateway API CRD not found; install standard-install.yaml first"
    echo "  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml"
    exit 1
  fi
fi

ADMIN_INGRESS_ENABLED=true
if [[ "$ADMIN_VIA_GATEWAY" == "true" ]]; then
  ADMIN_INGRESS_ENABLED=false
fi

echo "Deploying ${RELEASE_NAME} version ${VERSION} to namespace ${NAMESPACE}"
echo "  admin_host=${ADMIN_HOST} admin_via_gateway=${ADMIN_VIA_GATEWAY} replicas=${REPLICA_COUNT}"

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
  -f "$H255_VALUES" \
  --set image.tag="$VERSION" \
  --set image.pullPolicy=Always \
  --set auth.username=admin \
  --set auth.password=admin \
  --set auth0.domain="$AUTH0_DOMAIN" \
  --set auth0.clientId="$AUTH0_CLIENT_ID" \
  --set auth0.audience="$AUTH0_AUDIENCE" \
  --set adminIngress.enabled="$ADMIN_INGRESS_ENABLED" \
  --set adminIngress.host="$ADMIN_HOST" \
  --set adminIngress.tlsSecretName="$ADMIN_TLS_SECRET" \
  --set ingress.className=pertisk-eproxy \
  --set replicaCount="$REPLICA_COUNT" \
  --set autoscaling.enabled=true \
  --set autoscaling.minReplicas="$REPLICA_COUNT" \
  --set ingress.gatewayApiEnabled="$GATEWAY_API_ENABLED" \
  --set gatewayClassResource.enabled="$GATEWAYCLASS_ENABLED" \
  --set controller.config.quic_enabled=true

kubectl -n "$NAMESPACE" rollout status "deployment/$RELEASE_NAME" --timeout "$ROLLOUT_TIMEOUT"

if [[ "$ADMIN_VIA_GATEWAY" == "true" && "$APPLY_ADMIN_GATEWAY" == "true" ]]; then
  if [[ "$CLEANUP_LEGACY_GATEWAY_HOST" == "true" ]]; then
    echo "Removing legacy eproxy Gateway routes for admin.gateway.pertisk.com (use Rust rproxy for that host)..."
    kubectl delete httproute admin-gateway-httproute -n "$NAMESPACE" --ignore-not-found
    kubectl delete gateway pertisk-gateway -n "$NAMESPACE" --ignore-not-found
  fi
  echo "Applying Gateway API admin manifest..."
  kubectl apply -f "${REPO_ROOT}/deploy/gateway-api/admin-gateway.yaml" -n "$NAMESPACE"
fi

echo "Done. ${RELEASE_NAME} deployed with image tag ${VERSION}"
kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" -o wide
kubectl get gateway,httproute -n "$NAMESPACE" 2>/dev/null || true

if [[ "$VERIFY_ADMIN_UI" == "true" ]]; then
  ADMIN_URL="https://${ADMIN_HOST}"
  echo "Verifying admin UI at ${ADMIN_URL} ..."
  curl -sfI "${ADMIN_URL}/api/ingress/live" | head -5
fi
