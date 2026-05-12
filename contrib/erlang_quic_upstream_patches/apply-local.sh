#!/usr/bin/env bash
# Clone erlang_quic locally, apply pertisk interop patch, compile (local-first before GitHub PR).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PATCH="${SCRIPT_DIR}/pertisk-vendor-quic-interop-v1.3.0.patch"
UPSTREAM_URL="${ERLANG_QUIC_GIT_URL:-https://github.com/benoitc/erlang_quic.git}"
UPSTREAM_TAG="${ERLANG_QUIC_TAG:-v1.3.0}"

# Default: sibling directory ../erlang_quic next to this repo (override with ERLANG_QUIC_LOCAL).
if [[ -n "${ERLANG_QUIC_LOCAL:-}" ]]; then
  CLONE_DIR="${ERLANG_QUIC_LOCAL}"
else
  CLONE_DIR="$(cd "${REPO_ROOT}/.." && pwd)/erlang_quic"
fi

if [[ ! -f "$PATCH" ]]; then
  echo "Missing patch: $PATCH" >&2
  exit 1
fi

if [[ ! -d "${CLONE_DIR}/.git" ]]; then
  echo "Cloning ${UPSTREAM_URL} (tag ${UPSTREAM_TAG}) -> ${CLONE_DIR}"
  git clone --depth 1 --branch "${UPSTREAM_TAG}" "${UPSTREAM_URL}" "${CLONE_DIR}"
else
  echo "Using existing clone: ${CLONE_DIR}"
  if ! git -C "${CLONE_DIR}" diff-index --quiet HEAD -- 2>/dev/null; then
    echo "Working tree is not clean. Commit/stash or set ERLANG_QUIC_LOCAL to an empty directory." >&2
    exit 1
  fi
  git -C "${CLONE_DIR}" fetch --tags origin 2>/dev/null || true
  git -C "${CLONE_DIR}" checkout "${UPSTREAM_TAG}"
fi

echo "Applying patch..."
git -C "${CLONE_DIR}" apply --check "${PATCH}"
git -C "${CLONE_DIR}" apply "${PATCH}"

echo "Compiling (rebar3) in ${CLONE_DIR} ..."
(cd "${CLONE_DIR}" && rebar3 compile)

echo ""
echo "OK: patched and compiled. Next in ${CLONE_DIR}:"
echo "  git checkout -b fix/qpack-and-quic-socket-inet6"
echo "  git add src/qpack/quic_qpack.erl src/quic_socket.erl"
echo "  git commit -m 'QPACK: RFC 9204 Base for RIC=0; socket listener inet6 dual-stack'"
echo "  git push origin <branch>   # then open PR on github.com/benoitc/erlang_quic"
