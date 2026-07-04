#!/bin/bash
# Standard edition (primary): tiny DMG; the speech model is downloaded on first launch.
set -euo pipefail
exec "$(dirname "$0")/package.sh" --edition standard "$@"
