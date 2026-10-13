#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${RCT_BUILD_ROOT:-/tmp/RightClickText-Build}"
MODE="${1:-release}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application:.*\(8D9AHY5YW8\)/ {print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo 'Set SIGNING_IDENTITY to a valid signing identity hash for the configured Team.' >&2
  echo 'Use SIGNING_IDENTITY=- only for compile checks, not Finder/App Group testing.' >&2
  exit 1
fi

cd "$PROJECT_ROOT"
xcodegen generate
COMMON=(-project RightClickText.xcodeproj -scheme RightClickText -derivedDataPath "$BUILD_ROOT/DerivedData"
  "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO)
case "$MODE" in
  debug) xcodebuild "${COMMON[@]}" -configuration Debug build ;;
  release) xcodebuild "${COMMON[@]}" -configuration Release build ;;
  archive) xcodebuild "${COMMON[@]}" -configuration Release -archivePath "$BUILD_ROOT/RightClickText.xcarchive" archive ;;
  *) echo 'Usage: scripts/build.sh [debug|release|archive]' >&2; exit 2 ;;
esac
