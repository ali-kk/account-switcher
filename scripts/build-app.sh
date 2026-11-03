#!/bin/sh
# Builds "Claude Accounts.app" (menu bar only), signs it ad hoc and installs it in ~/Applications.
# Usage: scripts/build-app.sh [--no-install]
set -eu
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Claude Accounts"
BUNDLE_ID="com.orbital.claude-account-bar"
VERSION="1.0.0"
OUT="build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"

swift build -c release --product ClaudeAccountBar
BIN="$(swift build -c release --show-bin-path)/ClaudeAccountBar"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/ClaudeAccountBar"
cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ClaudeAccountBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal tool</string>
</dict>
</plist>
EOF
codesign --force --sign - --options runtime "$OUT"
codesign --verify --strict "$OUT"
echo "built: $OUT"

[ "${1:-}" = "--no-install" ] && exit 0

# Quit a running copy (only this app, by bundle id), then replace it.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
i=0; while pgrep -f "$DEST/Contents/MacOS/ClaudeAccountBar" >/dev/null && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$OUT" "$DEST"
open "$DEST"
echo "installed and started: $DEST"
