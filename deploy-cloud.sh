#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-0.5.10}"
NAMESPACE="${NAMESPACE:-pertisk-eproxy}"
RELEASE_NAME="${RELEASE_NAME:-pertisk-eproxy}"
CHART_PATH="${CHART_PATH:-pertisk/pertisk-eproxy}"
ADMIN_HOST="${ADMIN_HOST:-admin.cloud.thaidevops.co}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"

echo "Deploying ${RELEASE_NAME} version ${VERSION} to namespace ${NAMESPACE}"

# Build and push the ingress image, then deploy/update the Kubernetes release.
make docker-ingress-multi VERSION="$VERSION"
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  --set image.tag="$VERSION" \
  --set image.pullPolicy=Always \
  --set-string 'service.annotations.pertisk\.tech/floating-ip-enabled=true' \
  --set-string 'service.annotations.pertisk\.tech/floating-ip-family=dual-stack' \
  --set-string 'service.annotations.pertisk\.tech/floating-ip-home-location=nbg1' \
  --set auth.username=admin \
  --set auth.password='admin' \
  --set auth0.domain=dev-od6cfzs2tugxm53g.us.auth0.com \
  --set auth0.clientId=djuW8aR7VZQeS9SbW4ddnRCitgc6TiKO \
  --set auth0.audience=https://dev-od6cfzs2tugxm53g.us.auth0.com/api/v2/ \
  --set adminIngress.enabled=true \
  --set adminIngress.host="$ADMIN_HOST" \
  --set adminIngress.tlsSecretName=admin-cloud-tls