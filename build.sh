#!/bin/bash
# Builds Thermo.app (universal: Apple Silicon + Intel).
#   ./build.sh            build into ./build
#   ./build.sh --install  build and copy to /Applications, then open it
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Thermo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" Sources/*.swift -o "build/th-$arch" 2> >(grep -v "ld: warning" >&2)
done
lipo -create build/th-arm64 build/th-x86_64 -output "$APP/Contents/MacOS/Thermo"
rm build/th-*
swift tools/make_icon.swift build/Thermo.iconset
iconutil -c icns build/Thermo.iconset -o "$APP/Contents/Resources/Thermo.icns"
rm -rf build/Thermo.iconset
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Thermo</string>
  <key>CFBundleDisplayName</key><string>Thermo</string>
  <key>CFBundleIdentifier</key><string>local.thermo</string>
  <key>CFBundleExecutable</key><string>Thermo</string>
  <key>CFBundleIconFile</key><string>Thermo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Thermo || true
  rm -rf /Applications/Thermo.app
  cp -R "$APP" /Applications/
  open /Applications/Thermo.app
  echo "Installed to /Applications/Thermo.app"
fi
