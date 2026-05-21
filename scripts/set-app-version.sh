#!/usr/bin/env bash
# Stamp pertisk_eproxy application + relx release version before compile.
set -euo pipefail

VERSION="${1:?usage: set-app-version.sh <version>}"
VERSION="${VERSION#v}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="${ROOT}/src/pertisk_eproxy.app.src"
REBAR="${ROOT}/rebar.config"

if [ -z "$VERSION" ]; then
  echo "set-app-version: empty version" >&2
  exit 1
fi

perl -pi -e 's/\{vsn, "[^"]*"\}/{vsn, "'"${VERSION}"'"}/' "$APP_SRC"
perl -pi -e 's/\{release, \{pertisk_eproxy, "[^"]*"\}/\{release, {pertisk_eproxy, "'"${VERSION}"'"}/' "$REBAR"

echo "set-app-version: ${VERSION}"
