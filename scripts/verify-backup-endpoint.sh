#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <backup-export-url>" >&2
  echo "Example: $0 http://127.0.0.1:9080/api/backup/export" >&2
  exit 2
fi

url="$1"
tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

curl_args=(
  --fail
  --silent
  --show-error
  --max-time 20
)

if [[ -n "${PERTISK_BEARER_TOKEN:-}" ]]; then
  curl_args+=( -H "Authorization: Bearer ${PERTISK_BEARER_TOKEN}" )
fi

curl "${curl_args[@]}" "$url" > "$tmp_file"

jq empty "$tmp_file" >/dev/null

has_cert_records=$(jq 'has("certificate_records")' "$tmp_file")
if [[ "$has_cert_records" != "true" ]]; then
  echo "FAIL: missing certificate_records from $url"
  exit 1
fi

cert_records_count=$(jq '.certificate_records | length' "$tmp_file")
if [[ "$cert_records_count" -le 0 ]]; then
  echo "FAIL: certificate_records is empty from $url"
  exit 1
fi

bad_pem_count=$(jq '[.certificate_records[] | select((.cert_pem // "") == "" or (.key_pem // "") == "")] | length' "$tmp_file")
if [[ "$bad_pem_count" -gt 0 ]]; then
  echo "FAIL: cert_pem/key_pem missing for some records from $url"
  exit 1
fi

echo "PASS: $url certificate_records=$cert_records_count"
