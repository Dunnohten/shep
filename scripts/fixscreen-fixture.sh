#!/bin/bash
# Builds, launches and scores the test window for Shep's "fix this screen" label repair (tools/fixscreen-fixture/FixtureApp.swift).
#   scripts/fixscreen-fixture.sh build   compile the fixture into build/fixscreen-fixture/ShepLabelFixture.app (nothing is committed)
#   scripts/fixscreen-fixture.sh run     build if needed, then open the window "Shep Label Fixture"
#   scripts/fixscreen-fixture.sh scan    run `Shep --fix-screen-scan` on the open fixture (no model call, no writes) and score the flags:
#                                        every u* / btnPlay control should be flagged, no l* control should be
# Env: SHEP_FIXTURE_DIR (output folder, default build/fixscreen-fixture), SHEP_BIN (the Shep executable for `scan`).
set -euo pipefail
cd "$(dirname "$0")/.."

bundle_id="dev.shep.fixscreen.fixture"
out="${SHEP_FIXTURE_DIR:-build/fixscreen-fixture}"
app="$out/ShepLabelFixture.app"
shep_bin="${SHEP_BIN:-build/Build/Products/Debug/Shep.app/Contents/MacOS/Shep}"

usage() {
  echo "usage: scripts/fixscreen-fixture.sh build|run|scan" >&2
  exit 2
}

build_fixture() {
  mkdir -p "$app/Contents/MacOS"
  xcrun swiftc -O tools/fixscreen-fixture/FixtureApp.swift -o "$app/Contents/MacOS/ShepLabelFixture" \
    || { echo "could not compile tools/fixscreen-fixture/FixtureApp.swift" >&2; exit 3; }
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>ShepLabelFixture</string>
  <key>CFBundleExecutable</key><string>ShepLabelFixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
  echo "built: $app"
}

case "${1:-}" in
  build)
    build_fixture
    ;;
  run)
    [ -d "$app" ] || build_fixture
    open -n "$app"
    echo "opened: $app (bundle id $bundle_id)"
    ;;
  scan)
    [ -x "$shep_bin" ] || { echo "no Shep executable at $shep_bin (run scripts/build.sh, or set SHEP_BIN)" >&2; exit 3; }
    log="$(mktemp -t fixscreen-scan)"
    trap 'rm -f "$log"' EXIT
    "$shep_bin" --fix-screen-scan "$bundle_id" > "$log" || { echo "scan failed:" >&2; cat "$log" >&2; exit 4; }
    flagged_wanted="$(grep -cE '"flagged":true.*"identifier":"(btnPlay|u[0-9]+)"' "$log" || true)"
    total_wanted="$(grep -cE '"identifier":"(btnPlay|u[0-9]+)"' "$log" || true)"
    false_flags="$(grep -cE '"flagged":true.*"identifier":"l[0-9]+"' "$log" || true)"
    echo "unlabeled controls flagged: $flagged_wanted of $total_wanted"
    echo "labeled controls flagged (should be 0): $false_flags"
    echo "offerable (can be told apart): $(grep -cE '"flagged":true.*"offerable":true' "$log" || true); skipped (cannot be told apart): $(grep -cE '"flagged":true.*"offerable":false' "$log" || true)"
    grep '"kind":"summary"' "$log" || true
    ;;
  *)
    usage
    ;;
esac
