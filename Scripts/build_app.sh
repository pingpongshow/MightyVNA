#!/bin/bash
# Builds MightyVNA and assembles a double-clickable .app bundle.
#
#   ./Scripts/build_app.sh            release build into ./build/MightyVNA.app
#   ./Scripts/build_app.sh debug      debug build (faster to compile)
#
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/MightyVNA"
APP="$ROOT/build/MightyVNA.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MightyVNA"

VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>MightyVNA</string>
    <key>CFBundleDisplayName</key>          <string>MightyVNA</string>
    <key>CFBundleExecutable</key>           <string>MightyVNA</string>
    <key>CFBundleIdentifier</key>           <string>com.mightyvna.app</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
    <key>CFBundleVersion</key>              <string>${VERSION}</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSHumanReadableCopyright</key>     <string>MightyVNA</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSSupportsAutomaticTermination</key> <true/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>     <string>com.mightyvna.session</string>
            <key>UTTypeDescription</key>    <string>MightyVNA Session</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>mightyvna</string></array>
            </dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>     <string>MightyVNA Session</string>
            <key>CFBundleTypeRole</key>     <string>Editor</string>
            <key>LSItemContentTypes</key>
            <array><string>com.mightyvna.session</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>     <string>Touchstone File</string>
            <key>CFBundleTypeRole</key>     <string>Viewer</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>s1p</string><string>s2p</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (no Resources/AppIcon.icns — run Scripts/make_icon.swift to generate one)"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    codesign skipped"

echo "==> Done: $APP"
echo "    open \"$APP\""
