#!/usr/bin/env bash
# Minimal admin UI stubs for eunit (priv/admin/ is gitignored; Docker builds the real SPA).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_DIR="${ROOT_DIR}/priv/admin"
INDEX="${ADMIN_DIR}/index.html"
FAVICON="${ADMIN_DIR}/favicon.svg"

if [ -f "$INDEX" ] && [ -f "$FAVICON" ]; then
  exit 0
fi

mkdir -p "${ADMIN_DIR}/assets"

cat >"$INDEX" <<'EOF'
<!DOCTYPE html>
<html><head><title>test</title></head><body><html>test</body></html>
EOF

cat >"$FAVICON" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="#0066cc"/></svg>
EOF
