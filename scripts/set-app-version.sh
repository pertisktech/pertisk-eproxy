#!/usr/bin/env bash
# Stamp pertisk_eproxy application + relx release version before compile.
# Accepts: 0.5.64 | v0.5.64 | refs/tags/0.5.64 | refs/tags/v0.5.64
set -euo pipefail

VERSION="${1:?usage: set-app-version.sh <version>}"
VERSION="${VERSION#refs/tags/}"
VERSION="${VERSION#v}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="${ROOT}/src/pertisk_eproxy.app.src"
REBAR="${ROOT}/rebar.config"

if [ -z "$VERSION" ]; then
  echo "set-app-version: empty version" >&2
  exit 1
fi

case "$VERSION" in
  *[!A-Za-z0-9._-]*)
    echo "set-app-version: invalid version '${VERSION}'" >&2
    exit 1
    ;;
esac

# Use | as s/// delimiter so versions never collide with /.
perl -pi -e "s|\\{vsn, \"[^\"]*\"\\}|{vsn, \"${VERSION}\"}|" "$APP_SRC"
perl -pi -e "s|\\{release, \\{pertisk_eproxy, \"[^\"]*\"\\}|{release, {pertisk_eproxy, \"${VERSION}\"}|" "$REBAR"

echo "set-app-version: ${VERSION}"
