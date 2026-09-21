#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate
xcodebuild -scheme Filit -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' build
open build/Build/Products/Debug/Filit.app
