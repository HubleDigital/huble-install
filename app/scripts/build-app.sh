#!/bin/bash
# Build Huble.app (universal: arm64 + x86_64) from the SwiftPM package and
# zip it for a GitHub release.
#
#   scripts/build-app.sh --version 0.1.1                       ad-hoc signed (runs on this Mac only)
#   scripts/build-app.sh --version 0.1.1 --sign "Developer ID Application: Huble (TEAMID)"
#   scripts/build-app.sh --version 0.1.1 --sign "..." --notarize <notarytool keychain profile>
#
# --version is required (or HUBLE_APP_VERSION in the environment): the
# version goes into Info.plist and the zip name, and a stale default would
# ship the wrong number. Output: build/Huble.app and
# build/Huble-<version>-universal.zip (+ its SHA-256 on stdout).
# App icon: app/Icon.icns is used as-is; otherwise a 1024x1024 app/Icon.png is scaled into one.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY=""
NOTARIZE_PROFILE=""
VERSION="${HUBLE_APP_VERSION:-}"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE_PROFILE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [ -z "$VERSION" ]; then
  echo "--version X.Y.Z is required (or set HUBLE_APP_VERSION)" >&2; usage >&2; exit 2
fi
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "--version must look like X.Y.Z (got '$VERSION')" >&2; exit 2 ;;
esac
if [ -n "$NOTARIZE_PROFILE" ] && [ -z "$SIGN_IDENTITY" ]; then
  echo "--notarize needs --sign (Apple only notarizes Developer ID signed apps)" >&2; exit 2
fi

cd "$APP_DIR"
echo "==> swift build (release, universal arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Huble"
[ -x "$BIN" ] || { echo "binary not found at $BIN" >&2; exit 1; }
lipo -info "$BIN" | grep -q 'x86_64' && lipo -info "$BIN" | grep -q 'arm64' \
  || { echo "binary is not universal: $(lipo -info "$BIN")" >&2; exit 1; }

BUNDLE="$APP_DIR/build/Huble.app"
echo "==> assembling $BUNDLE ($VERSION)"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/Huble"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

ICON_PLIST=""
if [ -f "$APP_DIR/Icon.icns" ]; then
  # A finished icon set wins, used as-is (keeps any hand-tuned small sizes).
  cp "$APP_DIR/Icon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
  ICON_PLIST="	<key>CFBundleIconFile</key>
	<string>AppIcon</string>"
elif [ -f "$APP_DIR/Icon.png" ]; then
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

ZIP="$APP_DIR/build/Huble-$VERSION-universal.zip"
if [ -n "$NOTARIZE_PROFILE" ]; then
  echo "==> notarizing"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$BUNDLE"
fi
# The shipped zip is made AFTER signing (and stapling): it carries the ticket.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"

codesign -dv "$BUNDLE" 2>&1 | sed -n '1,3p'
lipo -info "$BUNDLE/Contents/MacOS/Huble"
echo "built: $BUNDLE"
echo "zip:   $ZIP"
echo "sha256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
