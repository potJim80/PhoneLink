#!/bin/bash
# Builds "Phone Link.app" in this folder from src/. Safe to re-run; it replaces
# the old bundle. Pass --install to also copy it into the Applications folder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Phone Link"
APP="$ROOT/$NAME.app"
BUILD="$ROOT/.build"

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found — run: xcode-select --install"; exit 1; }

rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

echo "compiling…"
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos15.0" \
	-framework AppKit -framework CoreAudio -framework AVFoundation -framework Network -framework SystemConfiguration \
	-o "$APP/Contents/MacOS/PhoneLink" "$ROOT"/src/*.swift

/bin/cp -R "$ROOT/src/page" "$APP/Contents/Resources/page"

ICON_OK=no
if /usr/bin/osascript -l JavaScript "$ROOT/src/make-icon.js" "$BUILD/icon.png" >/dev/null 2>&1 && [ -s "$BUILD/icon.png" ]; then
	/usr/bin/sips -z 512 512 "$BUILD/icon.png" --out "$APP/Contents/Resources/page/icon.png" >/dev/null 2>&1
	ISET="$BUILD/PhoneLink.iconset"; mkdir -p "$ISET"
	for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" \
		"256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
		/usr/bin/sips -z "${spec%% *}" "${spec%% *}" "$BUILD/icon.png" --out "$ISET/icon_${spec##* }.png" >/dev/null 2>&1
	done
	/usr/bin/iconutil -c icns "$ISET" -o "$APP/Contents/Resources/PhoneLink.icns" >/dev/null 2>&1 && ICON_OK=yes
fi
[ "$ICON_OK" = yes ] || { echo "error: icon could not be made (the phone page needs icon.png)"; exit 1; }

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Phone Link</string>
	<key>CFBundleDisplayName</key><string>Phone Link</string>
	<key>CFBundleIdentifier</key><string>local.mahdi.phonelink</string>
	<key>CFBundleExecutable</key><string>PhoneLink</string>
	<key>CFBundleIconFile</key><string>PhoneLink</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAudioCaptureUsageDescription</key><string>Phone Link sends the Mac’s sound to your iPhone, and turns the iPhone’s mic into a Mac microphone.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "note: could not sign; it will still run."
/usr/bin/touch "$APP"
rm -rf "$BUILD"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
	if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
	mkdir -p "$DEST"; rm -rf "$DEST/$NAME.app"
	/bin/cp -R "$APP" "$DEST/"; /usr/bin/touch "$DEST/$NAME.app"
	echo "Installed $DEST/$NAME.app"
fi
