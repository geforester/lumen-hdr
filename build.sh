#!/bin/bash
# Собирает «Lumen.app» в /Applications и CLI-симлинк ~/.local/bin/lumen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Applications/Lumen.app"
BIN_DIR="$HOME/.local/bin"
EXE=lumen
ID=com.geforester.lumen
TMP="$ROOT/.build"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BIN_DIR" "$TMP"

echo "==> Кернел (Metal для Core Image)"
xcrun metal -c -fcikernel "$ROOT/src/Lumen.ci.metal" -o "$TMP/Lumen.air"
xcrun metallib -cikernel "$TMP/Lumen.air" -o "$APP/Contents/Resources/Lumen.metallib"

echo "==> Компиляция"
swiftc -O -parse-as-library -swift-version 5 \
    -framework AppKit -framework SwiftUI -framework MetalKit -framework CoreImage \
    -o "$APP/Contents/MacOS/$EXE" "$ROOT/src/main.swift"

cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>$EXE</string>
    <key>CFBundleIdentifier</key>          <string>$ID</string>
    <key>CFBundleName</key>                <string>Lumen</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>      <string>26.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <!-- «Открыть в программе → Lumen» для любых картинок -->
    <key>CFBundleDocumentTypes</key>
    <array><dict>
        <key>CFBundleTypeName</key>        <string>Image</string>
        <key>CFBundleTypeRole</key>        <string>Viewer</string>
        <key>LSHandlerRank</key>           <string>Alternate</string>
        <key>LSItemContentTypes</key>      <array><string>public.image</string></array>
    </dict></array>
</dict>
</plist>
PLISTEOF

codesign --force --sign - --identifier "$ID" "$APP"
ln -sf "$APP/Contents/MacOS/$EXE" "$BIN_DIR/$EXE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

echo "==> Готово: $APP"
echo "    cli: $BIN_DIR/$EXE convert фото.jpg [-b 50] [-p 70] [--heic]"
