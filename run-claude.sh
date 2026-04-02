#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$ROOT/build.sh" >/dev/null

open "$ROOT/build/ClaudeWindowWatch.app"
