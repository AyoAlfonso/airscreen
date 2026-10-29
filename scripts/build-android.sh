#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../android-tv"
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
../tools/gradle-8.9/bin/gradle :app:assembleDebug
