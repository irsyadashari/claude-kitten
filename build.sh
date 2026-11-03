#!/bin/zsh
# Builds build/ClaudeKitten.app (no Xcode project needed, just the command line tools).
set -euo pipefail
cd "${0:A:h}"

APP=build/ClaudeKitten.app
FLAGS=(-swift-version 5 -O -target arm64-apple-macos14.0)

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "🐾 compiling app…"
swiftc "${FLAGS[@]}" Sources/Shared/*.swift Sources/App/*.swift -o "$APP/Contents/MacOS/ClaudeKitten"

echo "🐾 compiling hook helper…"
swiftc "${FLAGS[@]}" Sources/Shared/*.swift Sources/Hook/main.swift -o "$APP/Contents/MacOS/kitten-hook"

echo "🐾 drawing the icon…"
"$APP/Contents/MacOS/ClaudeKitten" --render-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.claudekitten.app</string>
  <key>CFBundleName</key><string>Claude Kitten</string>
  <key>CFBundleDisplayName</key><string>Claude Kitten</string>
  <key>CFBundleExecutable</key><string>ClaudeKitten</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ built $APP"
