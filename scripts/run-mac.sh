#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x AirScreen 2>/dev/null || true
AIRSCREEN_AUTOSTART=1 mac/build/Build/Products/Debug/AirScreen.app/Contents/MacOS/AirScreen
