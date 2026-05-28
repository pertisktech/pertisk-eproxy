#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <urls.txt>" >&2
  echo "Each line should be a full backup export URL, e.g. http://host:9080/api/backup/export" >&2
  exit 2
fi

urls_file="$1"
if [[ ! -f "$urls_file" ]]; then
  echo "ERROR: file not found: $urls_file" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
checker="$script_dir/verify-backup-endpoint.sh"

ok=0
fail=0

while IFS= read -r line || [[ -n "$line" ]]; do
  url=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [[ -z "$url" || "$url" == \#* ]]; then
    continue
  fi

  echo "Checking $url"
  if "$checker" "$url"; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
  echo "---"
done < "$urls_file"

echo "Summary: pass=$ok fail=$fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
