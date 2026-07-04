#!/bin/bash
# Complete edition: model bundled, 100% offline, ~2.7 GB DMG (manual distribution).
set -euo pipefail
exec "$(dirname "$0")/package.sh" --edition complete "$@"
