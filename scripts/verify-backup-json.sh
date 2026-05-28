#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <backup.json>" >&2
  exit 2
fi

backup_file="$1"

if [[ ! -f "$backup_file" ]]; then
  echo "ERROR: file not found: $backup_file" >&2
  exit 2
fi

jq empty "$backup_file" >/dev/null

has_cert_records=$(jq 'has("certificate_records")' "$backup_file")
if [[ "$has_cert_records" != "true" ]]; then
  echo "FAIL: missing certificate_records"
  exit 1
fi

cert_records_count=$(jq '.certificate_records | length' "$backup_file")
if [[ "$cert_records_count" -le 0 ]]; then
  echo "FAIL: certificate_records is empty"
  exit 1
fi

bad_pem_count=$(jq '[.certificate_records[] | select((.cert_pem // "") == "" or (.key_pem // "") == "")] | length' "$backup_file")
if [[ "$bad_pem_count" -gt 0 ]]; then
  echo "FAIL: found certificate_records entries without cert_pem or key_pem"
  exit 1
fi

has_tls_cert=$(jq 'has("tls_cert_file") and ((.tls_cert_file // "") != "")' "$backup_file")
has_tls_key=$(jq 'has("tls_key_file") and ((.tls_key_file // "") != "")' "$backup_file")
if [[ "$has_tls_cert" != "true" || "$has_tls_key" != "true" ]]; then
  echo "FAIL: missing tls_cert_file or tls_key_file"
  exit 1
fi

dns_count=$(jq '.dns_providers | length' "$backup_file")
if [[ "$dns_count" -le 0 ]]; then
  echo "WARN: dns_providers is empty"
fi

echo "PASS: backup looks complete"
echo "certificate_records=$cert_records_count dns_providers=$dns_count"
