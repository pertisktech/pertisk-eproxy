#!/bin/sh
# Copy vendored _checkouts/quic into deps/quic (rebar path dep; deps/ is gitignored).
set -e
ROOT="${REBAR_ROOT_DIR:-.}"
SRC="${ROOT}/_checkouts/quic"
DEST="${ROOT}/deps/quic"
if [ ! -f "${SRC}/src/qpack/quic_qpack.erl" ]; then
  echo "sync-quic-deps: missing ${SRC} (vendor quic into _checkouts/quic)" >&2
  exit 1
fi
rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"
cp -a "${SRC}" "${DEST}"
echo "sync-quic-deps: ${SRC} -> ${DEST}"
