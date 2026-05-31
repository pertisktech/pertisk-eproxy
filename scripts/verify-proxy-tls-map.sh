#!/usr/bin/env bash
set -euo pipefail

DB_PATH="${1:-data/proxy.db}"
HOST_FILTER="${2:-}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 not found" >&2
  exit 2
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not found" >&2
  exit 2
fi
if [[ ! -f "$DB_PATH" ]]; then
  echo "ERROR: DB not found: $DB_PATH" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# host|certificate_ref
SQL="SELECT host, COALESCE(certificate, '') FROM sites ORDER BY host;"
sqlite3 -separator '|' "$DB_PATH" "$SQL" > "$TMP_DIR/sites.txt"

if [[ -n "$HOST_FILTER" ]]; then
  grep -E "^${HOST_FILTER//./\\.}\|" "$TMP_DIR/sites.txt" > "$TMP_DIR/sites.filtered.txt" || true
  mv "$TMP_DIR/sites.filtered.txt" "$TMP_DIR/sites.txt"
fi

if [[ ! -s "$TMP_DIR/sites.txt" ]]; then
  if [[ -n "$HOST_FILTER" ]]; then
    echo "No site row found for host: $HOST_FILTER"
    exit 1
  fi
  echo "No site rows found"
  exit 1
fi

PASS=0
FAIL=0
MISS=0

while IFS='|' read -r HOST CERT_REF; do
  if [[ -z "$HOST" ]]; then
    continue
  fi

  if [[ -z "$CERT_REF" ]]; then
    echo "MISS  host=$HOST reason=no-certificate-ref"
    MISS=$((MISS + 1))
    continue
  fi

  CERT_PEM=""
  CERT_NAME=""

  if [[ "$CERT_REF" =~ ^[0-9]+$ ]]; then
    CERT_NAME="$(sqlite3 "$DB_PATH" "SELECT COALESCE(name,'') FROM certificates WHERE id=${CERT_REF};")"
    CERT_PEM="$(sqlite3 "$DB_PATH" "SELECT COALESCE(cert_pem,'') FROM certificates WHERE id=${CERT_REF};")"
  else
    CERT_NAME="$(sqlite3 "$DB_PATH" "SELECT COALESCE(name,'') FROM certificates WHERE name='${CERT_REF//\'/\'\'}' LIMIT 1;")"
    CERT_PEM="$(sqlite3 "$DB_PATH" "SELECT COALESCE(cert_pem,'') FROM certificates WHERE name='${CERT_REF//\'/\'\'}' LIMIT 1;")"
  fi

  if [[ -z "$CERT_PEM" ]]; then
    echo "MISS  host=$HOST cert_ref=$CERT_REF reason=certificate-not-found"
    MISS=$((MISS + 1))
    continue
  fi

  PEM_FILE="$TMP_DIR/cert.pem"
  printf '%s\n' "$CERT_PEM" > "$PEM_FILE"

  if openssl x509 -in "$PEM_FILE" -noout -checkhost "$HOST" >/dev/null 2>&1; then
    echo "PASS  host=$HOST cert_ref=$CERT_REF cert_name=${CERT_NAME:-$CERT_REF}"
    PASS=$((PASS + 1))
  else
    SUBJECT="$(openssl x509 -in "$PEM_FILE" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    SAN="$(openssl x509 -in "$PEM_FILE" -noout -ext subjectAltName 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
    echo "FAIL  host=$HOST cert_ref=$CERT_REF cert_name=${CERT_NAME:-$CERT_REF}"
    echo "      subject=$SUBJECT"
    echo "      san=$SAN"
    FAIL=$((FAIL + 1))
  fi
done < "$TMP_DIR/sites.txt"

echo "---"
echo "Summary: pass=$PASS fail=$FAIL missing=$MISS"

if [[ $FAIL -gt 0 || $MISS -gt 0 ]]; then
  exit 1
fi
