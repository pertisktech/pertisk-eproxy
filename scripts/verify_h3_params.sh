#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <host-or-url> [path]"
  echo "Examples:"
  echo "  $0 eproxy.example.com /"
  echo "  $0 admin.example.com/"
  echo "  $0 https://admin.example.com/api/health"
  exit 1
fi

INPUT="$1"
PATH_PART="${2:-}"

# Accept host, host/, or full URL and normalize into HOST + PATH_PART.
RAW="${INPUT#http://}"
RAW="${RAW#https://}"
RAW="${RAW%%\?*}"
RAW="${RAW%%#*}"

if [[ "$RAW" == */* ]]; then
  HOST_CANDIDATE="${RAW%%/*}"
  PATH_FROM_INPUT="/${RAW#*/}"
else
  HOST_CANDIDATE="${RAW%/}"
  PATH_FROM_INPUT="/"
fi

if [[ -z "$HOST_CANDIDATE" ]]; then
  echo "Invalid host input: $INPUT"
  exit 1
fi

HOST="$HOST_CANDIDATE"

if [[ -n "$PATH_PART" ]]; then
  # Caller-provided path wins; normalize leading slash.
  if [[ "$PATH_PART" != /* ]]; then
    PATH_PART="/$PATH_PART"
  fi
else
  PATH_PART="$PATH_FROM_INPUT"
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found"
  exit 1
fi

if ! curl --version | rg -qi 'ngtcp2|HTTP3|HTTP/3'; then
  echo "curl does not appear to support HTTP/3 (ngtcp2/nghttp3 missing)."
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

extract_params() {
  local trace="$1"
  local remote idle

  remote="$(printf '%s\n' "$trace" | rg -o 'remote transport\[[^]]+\]' | head -n 1 || true)"
  idle="$(printf '%s\n' "$trace" | rg -o 'peer idle timeout is [0-9]+ms' | head -n 1 || true)"

  if [[ -z "$remote" && -z "$idle" ]]; then
    echo "(no transport parameter lines found)"
  else
    [[ -n "$remote" ]] && echo "$remote"
    [[ -n "$idle" ]] && echo "$idle"
  fi
}

probe() {
  local label="$1"
  local url="$2"
  local required="$3"
  shift 3
  local extra=("$@")
  local trace
  local ok=0

  echo "==== $label ===="
  echo "URL: $url"

  if [[ ${#extra[@]} -gt 0 ]]; then
    trace="$(curl --http3-only -k --connect-timeout 6 --trace-ascii - --trace-config all,ids,time "${extra[@]}" "$url" -o /dev/null 2>&1)" || {
      printf '%s\n' "$trace" | rg -i 'Trying|Connected to|using HTTP/3|QUIC: connection|connect to .* failed|Failed to connect|Could not connect|refused' || true
      if [[ "$required" == "required" ]]; then
        echo "RESULT: FAIL (required check)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      else
        echo "RESULT: INFO (optional check failed)"
      fi
      echo
      return
    }
  else
    trace="$(curl --http3-only -k --connect-timeout 6 --trace-ascii - --trace-config all,ids,time "$url" -o /dev/null 2>&1)" || {
      printf '%s\n' "$trace" | rg -i 'Trying|Connected to|using HTTP/3|QUIC: connection|connect to .* failed|Failed to connect|Could not connect|refused' || true
      if [[ "$required" == "required" ]]; then
        echo "RESULT: FAIL (required check)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      else
        echo "RESULT: INFO (optional check failed)"
      fi
      echo
      return
    }
  fi

  if [[ -z "$trace" ]]; then
    printf '%s\n' "$trace" | rg -i 'Trying|Connected to|using HTTP/3|QUIC: connection|connect to .* failed|Failed to connect|Could not connect|refused' || true
    if [[ "$required" == "required" ]]; then
      echo "RESULT: FAIL (required check)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    else
      echo "RESULT: INFO (optional check failed)"
    fi
    echo
    return
  fi

  printf '%s\n' "$trace" | rg -i 'Trying|Connected to|using HTTP/3' | head -n 3 || true
  extract_params "$trace"

  if printf '%s\n' "$trace" | rg -q 'using HTTP/3' &&
     printf '%s\n' "$trace" | rg -q 'remote transport\['; then
    ok=1
  fi

  if [[ "$ok" -eq 1 ]]; then
    echo "RESULT: PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    if [[ "$required" == "required" ]]; then
      echo "RESULT: FAIL (required check)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    else
      echo "RESULT: INFO (optional check incomplete)"
    fi
  fi
  echo
}

check_http3_route() {
  local host="$1"
  local path="$2"
  local hdrs

  echo "==== route-h3:$path ===="
  hdrs="$(curl --http3-only -k -sS -o /dev/null -D - --resolve "$host:443:127.0.0.1" "https://$host$path" 2>/dev/null || true)"

  if printf '%s\n' "$hdrs" | rg -q '^HTTP/3 '; then
    printf '%s\n' "$hdrs" | rg -i '^HTTP/3|^content-type:|^alt-svc:' || true
    echo "RESULT: PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf '%s\n' "$hdrs" | sed -n '1,20p'
    echo "RESULT: FAIL (required route must be H3)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo
}

check_ws_http11_upgrade() {
  local host="$1"
  local hdrs

  echo "==== websocket-http1.1:/api/realtime ===="
  hdrs="$(curl -k -sS -o /dev/null -D - --http1.1 --resolve "$host:443:127.0.0.1" \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://$host/api/realtime" 2>/dev/null || true)"

  if printf '%s\n' "$hdrs" | rg -qi '^HTTP/1\.1 101 '; then
    printf '%s\n' "$hdrs" | rg -i '^HTTP/1\.1|^upgrade:|^connection:|^sec-websocket-accept:' || true
    echo "RESULT: PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf '%s\n' "$hdrs" | sed -n '1,24p'
    echo "RESULT: FAIL (required ws upgrade over HTTP/1.1)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo
}

for port in 443 444; do
  if [[ "$port" == "443" ]]; then
    probe "public-dns:$port" "https://$HOST:$port$PATH_PART" required
    probe "localhost-resolve:$port" "https://$HOST:$port$PATH_PART" required --resolve "$HOST:$port:127.0.0.1"
  else
    probe "public-dns:$port" "https://$HOST:$port$PATH_PART" optional
    probe "localhost-resolve:$port" "https://$HOST:$port$PATH_PART" required --resolve "$HOST:$port:127.0.0.1"
  fi
done

check_http3_route "$HOST" "/"
check_http3_route "$HOST" "/login"
check_http3_route "$HOST" "/api/auth/config"
check_http3_route "$HOST" "/api/version"
check_http3_route "$HOST" "/api/health"
check_ws_http11_upgrade "$HOST"

echo "==== summary ===="
echo "PASS checks: $PASS_COUNT"
echo "FAIL checks: $FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 2
fi
