#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-0.2.6}"
NAMESPACE="${NAMESPACE:-pertisk-eproxy}"

# Build and push the ingress image, then deploy/update the Kubernetes release.
make docker-ingress-multi VERSION="$VERSION"
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy -n "$NAMESPACE" \
  --create-namespace \
  --set image.tag="$VERSION" \
  --set auth.username=admin \
  --set auth.password='admin' \
  --set auth0.domain=dev-od6cfzs2tugxm53g.us.auth0.com \
  --set auth0.clientId=djuW8aR7VZQeS9SbW4ddnRCitgc6TiKO \
  --set auth0.audience=https://dev-od6cfzs2tugxm53g.us.auth0.com/api/v2/ \
  --set adminIngress.enabled=true \
  --set adminIngress.host=admin.cloud.thaidevops.co \
  --set adminIngress.tlsSecretName=admin-cloud-tls \
  --set service.externalTrafficPolicy=Local