#!/bin/bash
# Assembles dist/BulkGitHub.app from a SwiftPM release build.
# Ad-hoc signed for local use; CI release signing/notarization is separate
# (see .github/workflows/release.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="dist/BulkGitHub.app"
VERSION="${VERSION:-0.4.1}"

swift build -c "$CONFIG"

BIN=".build/$CONFIG/BulkGitHub"
[[ -x "$BIN" ]] || { echo "missing $BIN" >&2; exit 1; }
[[ -d ".build/$CONFIG/BulkGitHub_BulkGitHubKit.bundle" ]] || {
  echo "missing BulkGitHubKit resource bundle" >&2; exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/BulkGitHub"
# Every SwiftPM resource bundle the app links: our Kit (bulkgh.d.ts, tsc,
# recipes) plus dependencies' (Highlightr ships highlight.js + themes).
for bundle in .build/"$CONFIG"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
if [[ -f Assets/AppIcon.icns ]]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>BulkGitHub</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>me.geo.bulkgithub</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>BulkGitHub</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Steve Meyfroidt. Licensed under the GNU GPL v3.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP (config: $CONFIG, version: $VERSION)"
