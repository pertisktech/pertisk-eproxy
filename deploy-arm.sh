#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-0.4.25}"
NAMESPACE="${NAMESPACE:-pertisk-eproxy}"
RELEASE_NAME="${RELEASE_NAME:-pertisk-eproxy}"
CHART_PATH="${CHART_PATH:-./deploy/helm/pertisk-eproxy}"
ADMIN_HOST="${ADMIN_HOST:-admin.arm.thaidevops.co}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
SMOKE_URL="${SMOKE_URL:-https://${ADMIN_HOST}/docs}"

echo "Deploying ${RELEASE_NAME} version ${VERSION} to namespace ${NAMESPACE}"

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
  --set adminIngress.tlsSecretName=admin-arm-tls

echo "Smoke check: ${SMOKE_URL}"
if curl -fsSL --max-time 25 "$SMOKE_URL" | grep -qi 'swagger-ui'; then
  echo "Swagger docs check passed"
else
  echo "Swagger docs check failed: ${SMOKE_URL}" >&2
  exit 1
fi