#!/bin/bash
# Generate the Xcode project from project.yml and build the app (Debug, unsigned).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Shep.xcodeproj -scheme Shep -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
echo "built: build/Build/Products/Debug/Shep.app"
echo "dock demo: build/Build/Products/Debug/Shep.app/Contents/MacOS/Shep --dock-demo"
