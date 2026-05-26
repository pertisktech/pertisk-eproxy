#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:9080}"
API_URL="${BASE_URL%/}/api/dns-providers/validate"
AUTH_LOGIN_URL="${BASE_URL%/}/api/auth/login"
RESOLVED_TOKEN="${ADMIN_TOKEN:-}"

TMP_BODY="$(mktemp)"
cleanup() {
  rm -f "$TMP_BODY"
}
trap cleanup EXIT

post_json() {
  local payload="$1"
  if [[ -n "$RESOLVED_TOKEN" ]]; then
    curl -sS -X POST "${API_URL}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${RESOLVED_TOKEN}" \
      --data "$payload" \
      -o "$TMP_BODY" \
      -w "%{http_code}"
  else
    curl -sS -X POST "${API_URL}" \
      -H "Content-Type: application/json" \
      --data "$payload" \
      -o "$TMP_BODY" \
      -w "%{http_code}"
  fi
}

try_login_for_token() {
  if [[ -n "$RESOLVED_TOKEN" ]]; then
    return 0
  fi
  if [[ -z "${ADMIN_USERNAME:-}" || -z "${ADMIN_PASSWORD:-}" ]]; then
    return 1
  fi

  local login_body
  login_body="$(mktemp)"
  local login_status
  login_status="$(curl -sS -X POST "${AUTH_LOGIN_URL}" \
    -H "Content-Type: application/json" \
    --data "{\"username\":\"${ADMIN_USERNAME}\",\"password\":\"${ADMIN_PASSWORD}\"}" \
    -o "$login_body" \
    -w "%{http_code}")"

  if [[ "$login_status" == "200" ]]; then
    RESOLVED_TOKEN="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$login_body")"
  fi

  rm -f "$login_body"
  [[ -n "$RESOLVED_TOKEN" ]]
}

assert_contains() {
  local expected="$1"
  if ! grep -Fq "$expected" "$TMP_BODY"; then
    echo "Expected response to contain: $expected"
    echo "Actual response:"
    cat "$TMP_BODY"
    exit 1
  fi
}

echo "[1/3] missing provider_type should return 400"
status="$(post_json '{"credentials":{}}')"
if [[ "$status" == "401" ]]; then
  if try_login_for_token; then
    status="$(post_json '{"credentials":{}}')"
  else
    echo "Admin API requires auth. Set ADMIN_TOKEN or ADMIN_USERNAME/ADMIN_PASSWORD and rerun."
    cat "$TMP_BODY"
    exit 2
  fi
fi
[[ "$status" == "400" ]] || { echo "Expected HTTP 400, got $status"; cat "$TMP_BODY"; exit 1; }
assert_contains 'provider_type is required'

echo "[2/3] native provider (duckdns) should validate with minimal required fields"
status="$(post_json '{"provider_type":"duckdns","credentials":{"domain":"example","token":"dummy-token"}}')"
[[ "$status" == "200" ]] || { echo "Expected HTTP 200, got $status"; cat "$TMP_BODY"; exit 1; }
assert_contains '"ok":true'
assert_contains 'duckdns'

echo "[3/3] lego provider (route53) should fail cleanly when not fully configured"
status="$(post_json '{"provider_type":"route53","credentials":{}}')"
[[ "$status" == "400" ]] || { echo "Expected HTTP 400, got $status"; cat "$TMP_BODY"; exit 1; }
if grep -Fq 'lego_not_found' "$TMP_BODY"; then
  :
elif grep -Fq 'missing_access_key_id' "$TMP_BODY"; then
  :
else
  echo "Expected lego_not_found or missing_access_key_id in response"
  cat "$TMP_BODY"
  exit 1
fi

echo "DNS provider validate API integration checks passed."