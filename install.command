#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if "$ROOT/install.sh"; then
  status=0
else
  status=$?
fi

printf '\nPress Return to close...'
read -r _
exit "$status"
