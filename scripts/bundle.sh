#!/bin/sh
# Builds Showtell.app into ./build. macOS asks for microphone and Accessibility
# permission per app bundle, so run the bundle, not the bare binary.
#
#   scripts/bundle.sh            release build
#   scripts/bundle.sh debug      debug build
set -eu
cd "$(dirname "$0")/.."
config="${1:-release}"
swift build -c "$config" --product Showtell
bin="$(swift build -c "$config" --show-bin-path)"

app=build/Showtell.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Showtell" "$app/Contents/MacOS/Showtell"
for b in "$bin"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.showtell.Showtell</string>
  <key>CFBundleName</key><string>Showtell</string>
  <key>CFBundleDisplayName</key><string>Showtell</string>
  <key>CFBundleExecutable</key><string>Showtell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Showtell transcribes what you say, on this Mac, and sends it to the Claude Code session you opened.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with a stable identifier, so permission grants survive rebuilds as far as macOS allows.
# A stable identity keeps macOS permissions (Accessibility, Microphone) across rebuilds; ad-hoc
# signatures change with every build. Create one with scripts/make-signing-cert.sh.
identity=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/"Showtell Local Signing"/ {print $2; exit}')
codesign --force --deep --sign "${identity:--}" --identifier dev.showtell.Showtell "$app"
echo "built $app"
