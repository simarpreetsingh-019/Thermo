#!/bin/bash
# Builds Thermo.app (universal: Apple Silicon + Intel).
#   ./build.sh            build into ./build
#   ./build.sh --install  build and copy to /Applications, then open it
#   ./build.sh --no-connect  leave out the CLI JSON output, MCP server and local API (Sources/Connect.swift)
set -euo pipefail
FLAGS=(); [[ " $* " == *" --no-connect "* ]] && FLAGS=(-D NO_CONNECT) && echo "Building without connections (CLI/MCP/API)"
cd "$(dirname "$0")"
APP=build/Thermo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O ${FLAGS[@]+"${FLAGS[@]}"} -target "$arch-apple-macos13.0" Sources/*.swift -o "build/th-$arch" 2> >(grep -v "ld: warning" >&2)
done
lipo -create build/th-arm64 build/th-x86_64 -output "$APP/Contents/MacOS/Thermo"
rm build/th-*
swift tools/make_icon.swift build/Thermo.iconset
iconutil -c icns build/Thermo.iconset -o "$APP/Contents/Resources/Thermo.icns"
cp tools/thermo "$APP/Contents/Resources/thermo"   # `thermo` command, linked onto the PATH by the Homebrew cask
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
  <key>CFBundleShortVersionString</key><string>1.9.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Simarpreet Singh · simarpreetsingh-019.github.io · MIT License</string>
</dict></plist>
PLIST
codesign --force --options runtime -s - "$APP"   # ad-hoc + hardened runtime
echo "Built $APP"
if [[ " $* " == *" --install "* ]]; then
  pkill -x Thermo || true
  rm -rf /Applications/Thermo.app
  cp -R "$APP" /Applications/
  open /Applications/Thermo.app
  echo "Installed to /Applications/Thermo.app"
  echo ""
  echo "  🌡️  Thermo is installed — created by Simarpreet Singh"
  echo "     simarpreetsingh-019.github.io · x.com/simarpreet_019"
  echo "     ⭐ Like it? Star or fork: https://github.com/simarpreetsingh-019/Thermo"
fi
