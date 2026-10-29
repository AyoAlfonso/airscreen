#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../mac"
xcodegen generate
xcodebuild -project AirScreen.xcodeproj -scheme AirScreen \
  -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
