#!/bin/zsh
# Builds a release binary and wraps it in "ePerformance View.app" (menu bar only, ad-hoc signed).
# The version comes from the VERSION file; the updater compares it with the latest GitHub release.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION)
swift build -c release
APP="build/ePerformance View.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ePerformanceView "$APP/Contents/MacOS/ePerformanceView"

# App icon from the 1024 px master (Icon/make-icon.swift draws it).
if [[ ! -f Icon/icon-1024.png ]]; then
  swiftc -O -o .build/make-icon Icon/make-icon.swift && .build/make-icon Icon/icon-1024.png
fi
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ePerformance View</string>
  <key>CFBundleDisplayName</key><string>ePerformance View</string>
  <key>CFBundleIdentifier</key><string>solutions.ionicx.monitorleve</string>
  <key>CFBundleExecutable</key><string>ePerformanceView</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Usado apenas para executar o purge com a senha de administrador.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Pronto: $PWD/$APP ($VERSION)"
