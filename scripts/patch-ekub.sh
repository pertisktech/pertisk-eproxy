#!/bin/sh
# ekub 0.2.0 sets fail_if_no_peer_cert (server-only) — breaks in-cluster K8s API TLS.
set -e
ROOT="${REBAR_ROOT_DIR:-.}"
PATCH="${ROOT}/contrib/patches/ekub-ssl-client-k8s.patch"
found=0
for f in $(find "${ROOT}/_build" -path '*/ekub/src/ekub_core.erl' 2>/dev/null); do
  found=1
  dir=$(dirname "$f")/..
  patch -p1 -d "$dir" -N -i "$PATCH" 2>/dev/null \
    || perl -i -0pe 's/\[\{fail_if_no_peer_cert, true\},\s*\n\s*\{server_name_indication/[{server_name_indication/s' "$f"
  rm -f "$(dirname "$f")/../ebin/ekub_core.beam" 2>/dev/null || true
done
if [ "$found" -eq 0 ]; then
  echo "patch-ekub: no ekub_core.erl under _build (run rebar3 get-deps first)" >&2
  exit 1
fi
if grep -q fail_if_no_peer_cert $(find "${ROOT}/_build" -path '*/ekub/src/ekub_core.erl' | head -1); then
  echo "patch-ekub: fail_if_no_peer_cert still present" >&2
  exit 1
fi
echo "patch-ekub: ok"
