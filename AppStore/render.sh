#!/bin/bash
# Renders the App Store screenshots (6.9", 1320 × 2868) from the raw simulator
# captures in raw/ and the layout in compose.html. Needs Google Chrome.
#
#   ./AppStore/render.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
port=8766
profile="$(mktemp -d)"

# Served from the repo root so the page can load the app's own fonts.
(cd "$repo" && exec python3 -m http.server "$port" >/dev/null 2>&1) &
server=$!
trap 'kill "$server" 2>/dev/null; rm -rf "$profile"' EXIT
sleep 1

for n in 1 2 3 4 5; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --user-data-dir="$profile" --window-size=1320,2868 --virtual-time-budget=4000 \
    --screenshot="$repo/AppStore/screenshots/0$n.png" \
    "http://localhost:$port/AppStore/compose.html?n=$n" >/dev/null 2>&1
  echo "rendered AppStore/screenshots/0$n.png"
done
