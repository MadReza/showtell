#!/bin/sh
# Builds Showtell and installs it as /Applications/Showtell.app, replacing a running copy.
set -eu
cd "$(dirname "$0")/.."
scripts/bundle.sh
pkill -x Showtell 2>/dev/null && sleep 1 || true
rm -rf /Applications/Showtell.app
ditto build/Showtell.app /Applications/Showtell.app
open /Applications/Showtell.app
echo "installed /Applications/Showtell.app"
