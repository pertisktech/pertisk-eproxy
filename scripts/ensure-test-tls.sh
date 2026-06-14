#!/usr/bin/env bash
# Self-signed listener PEM for eunit (priv/tls/ is gitignored; Docker builds generate these).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS_DIR="${ROOT_DIR}/priv/tls"
CERT="${TLS_DIR}/listener.pem"
KEY="${TLS_DIR}/listener.key"

if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ensure-test-tls: openssl not found (need listener.pem + listener.key under priv/tls/)" >&2
  exit 1
fi

mkdir -p "$TLS_DIR"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$KEY" -out "$CERT" \
  -days 3650 -nodes -subj "/CN=localhost"
chmod 600 "$KEY"
