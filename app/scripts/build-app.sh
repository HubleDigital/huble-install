#!/bin/bash
# Build Huble.app from the SwiftPM package.
#
#   scripts/build-app.sh                       ad-hoc signed (runs on this Mac only)
#   scripts/build-app.sh --sign "Developer ID Application: Huble (TEAMID)"
#   scripts/build-app.sh --sign "..." --notarize <notarytool keychain profile>
#
# Drop a 1024x1024 app/Icon.png next to Package.swift to get an app icon.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY=""
NOTARIZE_PROFILE=""
VERSION="0.1.0"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE_PROFILE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [ -n "$NOTARIZE_PROFILE" ] && [ -z "$SIGN_IDENTITY" ]; then
  echo "--notarize needs --sign (Apple only notarizes Developer ID signed apps)" >&2; exit 2
fi

cd "$APP_DIR"
echo "==> swift build (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Huble"
[ -x "$BIN" ] || { echo "binary not found at $BIN" >&2; exit 1; }

BUNDLE="$APP_DIR/build/Huble.app"
echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/Huble"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

ICON_PLIST=""
if [ -f "$APP_DIR/Icon.png" ]; then
  ICONSET="$APP_DIR/build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$APP_DIR/Icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$APP_DIR/Icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
  ICON_PLIST="	<key>CFBundleIconFile</key>
	<string>AppIcon</string>"
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Huble</string>
	<key>CFBundleIdentifier</key>
	<string>com.hubledigital.huble</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Huble</string>
	<key>CFBundleDisplayName</key>
	<string>Huble</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Huble Digital</string>
$ICON_PLIST
</dict>
</plist>
PLIST

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> codesign (Developer ID, hardened runtime)"
  codesign --force --deep --options runtime --timestamp -s "$SIGN_IDENTITY" "$BUNDLE"
else
  echo "==> codesign (ad-hoc)"
  codesign --force --deep -s - "$BUNDLE"
fi

if [ -n "$NOTARIZE_PROFILE" ]; then
  ZIP="$APP_DIR/build/Huble.zip"
  echo "==> notarizing"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$BUNDLE"
  rm -f "$ZIP"
  # Ship this zip: it carries the stapled ticket.
  ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  echo "notarized zip: $ZIP"
fi

codesign -dv "$BUNDLE" 2>&1 | sed -n '1,3p'
echo "built: $BUNDLE"
