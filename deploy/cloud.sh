#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-0.5.47}"
NAMESPACE="${NAMESPACE:-pertisk-eproxy}"
RELEASE_NAME="${RELEASE_NAME:-pertisk-eproxy}"
CHART_PATH="${CHART_PATH:-./deploy/helm/pertisk-eproxy}"
ADMIN_HOST="${ADMIN_HOST:-admin.cloud.thaidevops.co}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
FORCE_DEPLOY="${FORCE_DEPLOY:-false}"
FORCE_RECREATE_DEPLOYMENT="${FORCE_RECREATE_DEPLOYMENT:-true}"
AUTO_RESOLVE_HELM_CONFLICT="${AUTO_RESOLVE_HELM_CONFLICT:-true}"
CPU_REQUEST="${CPU_REQUEST:-500m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-512Mi}"
CPU_LIMIT="${CPU_LIMIT:-1000m}"
MEMORY_LIMIT="${MEMORY_LIMIT:-1Gi}"

echo "Deploying ${RELEASE_NAME} version ${VERSION} to namespace ${NAMESPACE}"

if [[ "${FORCE_DEPLOY}" == "true" ]]; then
  echo "FORCE_DEPLOY=true: enabling Deployment recreate strategy (no Helm --force in server-side apply mode)"

  if [[ "${FORCE_RECREATE_DEPLOYMENT}" == "true" ]]; then
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
      echo "FORCE_RECREATE_DEPLOYMENT=true: deleting Deployment ${NAMESPACE}/${RELEASE_NAME} before Helm upgrade"
      kubectl -n "$NAMESPACE" delete deployment "$RELEASE_NAME" --ignore-not-found=true
    else
      echo "Namespace ${NAMESPACE} does not exist yet, skipping pre-delete"
    fi
  fi
fi

make docker-ingress-multi VERSION="$VERSION"

run_helm_upgrade() {
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
    --set adminIngress.tlsSecretName=admin-cloud-tls \
    --set controller.config.proxy_access_log=false \
    --set resources.requests.cpu="$CPU_REQUEST" \
    --set resources.requests.memory="$MEMORY_REQUEST" \
    --set resources.limits.cpu="$CPU_LIMIT" \
    --set resources.limits.memory="$MEMORY_LIMIT" \
    --set-string service.annotations."pertisk\.tech/floating-ip-enabled"=true \
    --set-string service.annotations."pertisk\.tech/floating-ip-family"=dual-stack \
    --set-string service.annotations."pertisk\.tech/floating-ip-home-location"=nbg1 \
    --set ingress.gatewayApiEnabled=true \
    --set gatewayClassResource.enabled=true
}

HELM_LOG="$(mktemp)"
set +e
run_helm_upgrade 2>&1 | tee "$HELM_LOG"
helm_exit=${PIPESTATUS[0]}
set -e

if [[ "$helm_exit" -ne 0 ]] && [[ "$AUTO_RESOLVE_HELM_CONFLICT" == "true" ]]; then
  if grep -q 'conflict occurred while applying object' "$HELM_LOG" \
    && grep -q 'Kind=Deployment' "$HELM_LOG"; then
    echo "Detected Helm deployment field-manager conflict. Recreating ${NAMESPACE}/${RELEASE_NAME} and retrying once."
    kubectl -n "$NAMESPACE" delete deployment "$RELEASE_NAME" --ignore-not-found=true
    run_helm_upgrade
    rm -f "$HELM_LOG"
    exit 0
  fi
fi

rm -f "$HELM_LOG"

if [[ "$helm_exit" -ne 0 ]]; then
  exit "$helm_exit"
fi
