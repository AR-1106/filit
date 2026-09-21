#!/usr/bin/env bash
# Build a Release Filit.app and zip it for GitHub Releases / Homebrew.
# Env:
#   VERSION       marketing version (required), e.g. 0.1.1
#   BUILD_NUMBER  CFBundleVersion (optional, default 1)
#   DERIVED_DATA  xcodebuild derivedDataPath (optional)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:?VERSION is required (e.g. 0.1.1)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DERIVED_DATA="${DERIVED_DATA:-dist/DerivedData}"
OUT_DIR="${OUT_DIR:-dist}"
APP_NAME="Filit.app"
ZIP_NAME="Filit-${VERSION}.zip"

mkdir -p "$OUT_DIR"

echo "Building Filit ${VERSION} (${BUILD_NUMBER})…"
xcodebuild \
  -project Filit.xcodeproj \
  -scheme Filit \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

APP_SRC="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}"
test -d "$APP_SRC"

STAGE="${OUT_DIR}/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP_SRC" "${STAGE}/${APP_NAME}"
xattr -cr "${STAGE}/${APP_NAME}" || true
codesign --force --deep --sign - "${STAGE}/${APP_NAME}"

rm -f "${OUT_DIR}/${ZIP_NAME}"
ditto -c -k --keepParent "${STAGE}/${APP_NAME}" "${OUT_DIR}/${ZIP_NAME}"
rm -rf "$STAGE"

echo "Wrote ${OUT_DIR}/${ZIP_NAME}"
shasum -a 256 "${OUT_DIR}/${ZIP_NAME}"
