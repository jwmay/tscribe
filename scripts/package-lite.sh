#!/bin/bash
# Lite edition: tiny DMG; the speech model is downloaded on first launch.
set -euo pipefail
exec "$(dirname "$0")/package.sh" --edition lite "$@"
