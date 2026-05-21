#!/bin/sh
# ekub 0.2.0: fail_if_no_peer_cert (server-only) and SNI=undefined break K8s API TLS.
set -e
ROOT="${REBAR_ROOT_DIR:-.}"
PATCH="${ROOT}/contrib/patches/ekub-ssl-client-k8s.patch"
found=0
for f in $(find "${ROOT}/_build" -path '*/ekub/src/ekub_core.erl' 2>/dev/null); do
  found=1
  if grep -q 'lists:filtermap(ssl_option_fun(Access), ?SslOptions).' "$f" \
     && ! grep -qE 'fail_if_no_peer_cert|server_name_indication, undefined' "$f"; then
    continue
  fi
  dir=$(dirname "$f")/..
  if [ -f "$PATCH" ] && patch -p1 -d "$dir" -N -i "$PATCH" 2>/dev/null; then
    :
  else
    sed -i '/fail_if_no_peer_cert/d' "$f" 2>/dev/null \
      || sed -i '' '/fail_if_no_peer_cert/d' "$f"
    sed -i '/server_name_indication, undefined/d' "$f" 2>/dev/null \
      || sed -i '' '/server_name_indication, undefined/d' "$f"
    sed -i '/not specifying at all/d' "$f" 2>/dev/null \
      || sed -i '' '/not specifying at all/d' "$f"
    sed -i "/is not the same as 'undefined'/d" "$f" 2>/dev/null \
      || sed -i '' "/is not the same as 'undefined'/d" "$f"
    sed -i 's/^[[:space:]]*|lists:filtermap/    lists:filtermap/' "$f" 2>/dev/null \
      || sed -i '' 's/^[[:space:]]*|lists:filtermap/    lists:filtermap/' "$f"
    sed -i 's/?SslOptions)\]\.$/?SslOptions)./' "$f" 2>/dev/null \
      || sed -i '' 's/?SslOptions)\]\.$/?SslOptions)./' "$f"
  fi
  rm -f "$(dirname "$f")/../ebin/ekub_core.beam" 2>/dev/null || true
done
if [ "$found" -eq 0 ]; then
  echo "patch-ekub: no ekub_core.erl under _build (run rebar3 get-deps first)" >&2
  exit 1
fi
EKUB_SRC=$(find "${ROOT}/_build" -path '*/ekub/src/ekub_core.erl' | head -1)
if grep -qE 'fail_if_no_peer_cert|server_name_indication, undefined|\?SslOptions\)\]\.|is not the same as' "$EKUB_SRC"; then
  echo "patch-ekub: ekub SSL patch incomplete" >&2
  exit 1
fi
if ! grep -q 'lists:filtermap(ssl_option_fun(Access), ?SslOptions).' "$EKUB_SRC"; then
  echo "patch-ekub: ssl_options/1 not in expected form" >&2
  exit 1
fi
echo "patch-ekub: ok"
