#!/usr/bin/env bash
# Patch hackney to avoid compile-time ct_expand cert decoding, which can fail
# in some build environments when ASN.1 NIF loading is unavailable during
# parse transforms.
set -euo pipefail

ROOT="${REBAR_ROOT_DIR:-.}"
HACKNEY_SSL=$(find "${ROOT}/_build" -path '*/hackney/src/hackney_ssl.erl' 2>/dev/null | head -1)

if [ -z "${HACKNEY_SSL}" ] || [ ! -f "${HACKNEY_SSL}" ]; then
  echo "patch-hackney: warning: no hackney_ssl.erl under _build (run rebar3 get-deps first)" >&2
  exit 0
fi

if grep -q 'patch-hackney runtime decoded_cacerts' "${HACKNEY_SSL}"; then
  echo "patch-hackney: already applied"
  exit 0
fi

if perl -0777 -ne 'exit((/decoded_cacerts\(\)\s*->\s*ct_expand:term\(/s)?0:1)' "${HACKNEY_SSL}"; then
  perl -0777 -i -pe 's@decoded_cacerts\(\)\s*->.*?\n\s*check_cert\(CACerts, Cert\) ->@decoded_cacerts() ->\n  %% patch-hackney runtime decoded_cacerts\n  lists:foldl(fun(Cert, Acc) ->\n                  Dec = public_key:pkix_decode_cert(Cert, otp),\n                  [hackney_ssl_certificate:public_key_info(Dec) | Acc]\n              end, [], certifi:cacerts()).\n\ncheck_cert(CACerts, Cert) ->@s' "${HACKNEY_SSL}"
fi

if perl -0777 -ne 'exit((/decoded_cacerts\(\)\s*->\s*ct_expand:term\(/s)?0:1)' "${HACKNEY_SSL}"; then
  echo "patch-hackney: failed to patch decoded_cacerts in ${HACKNEY_SSL}" >&2
  exit 1
fi

echo "patch-hackney: ok"
