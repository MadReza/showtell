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
cp Resources/AppIcon.icns "$app/Contents/Resources/"
for b in "$bin"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"
done
# llama.cpp (runs the downloadable clean-up models) is a framework next to the binary.
mkdir -p "$app/Contents/Frameworks"
ditto "$bin/llama.framework" "$app/Contents/Frameworks/llama.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Showtell" 2>/dev/null || true

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Showtell finds Claude Code sessions in iTerm2 tabs and pastes your message into the one you opened.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Showtell transcribes what you say, on this Mac, and sends it to the Claude Code session you opened.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Showtell uses Apple's on-device recogniser for French dictation; nothing leaves this Mac.</string>
</dict>
</plist>
PLIST

# A stable identity keeps macOS permissions (Accessibility, Microphone) across rebuilds; ad-hoc
# signatures change with every build. Create one with scripts/make-signing-cert.sh.
identity=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/"Showtell Local Signing"/ {print $2; exit}')
codesign --force --sign "${identity:--}" "$app/Contents/Frameworks/llama.framework"
codesign --force --deep --sign "${identity:--}" --identifier dev.showtell.Showtell "$app"
echo "built $app"
