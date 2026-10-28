#!/bin/bash
# Headless unit tests for ShepCore (pure logic; no app host, no permissions needed).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check-rules.sh
bash scripts/test-scripts.sh
xcodegen generate
xcodebuild -project Shep.xcodeproj -scheme ShepCore -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
