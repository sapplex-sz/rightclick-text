#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
# Avoid iCloud Drive metadata interfering with codesigned test executables.
swift test --scratch-path "${RCT_TEST_BUILD_ROOT:-/tmp/RightClickText-CoreTests}"
