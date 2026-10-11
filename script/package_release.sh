#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Stillset"
IDENTITY="${STILLSET_CODESIGN_IDENTITY:-Stillset Release}"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

security find-identity -p codesigning -v \
  | grep -F "\"$IDENTITY\"" >/dev/null \
  || {
    echo "Missing signing identity: $IDENTITY" >&2
    echo "Run ./script/setup_release_certificate.sh first." >&2
    exit 1
  }

rm -rf "$APP_BUNDLE"
xcodebuild -quiet \
  -project "$ROOT_DIR/Stillset.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ROOT_DIR/.build/Release" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  build

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_BUNDLE/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected version: $VERSION" >&2; exit 1; }
ZIP_NAME="$APP_NAME-v$VERSION.zip"
ZIP_PATH="$ROOT_DIR/dist/$ZIP_NAME"
DSYM="$ROOT_DIR/.build/Release/Build/Products/Release/$APP_NAME.app.dSYM"
DSYM_ZIP="$ROOT_DIR/dist/$APP_NAME-v$VERSION.dSYM.zip"

[[ "$(lipo -archs "$APP_BINARY")" == "arm64" ]] || exit 1
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -F "Authority=$IDENTITY" >/dev/null

if find "$APP_BUNDLE" -type f \( \
  -name '*.p12' -o -name '*.pem' -o -name '*.key' \
  -o -name '*.mobileprovision' -o -name '.env*' -o -name '*.dylib' \
\) -print -quit | grep -q .; then
  echo "Release bundle contains a private, provisioning, or debug file" >&2
  exit 1
fi

if strings "$APP_BINARY" \
  | grep -Ei '/Users/|[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' >/dev/null; then
  echo "Release binary contains a personal path or email address" >&2
  exit 1
fi

[[ "$(xcrun dwarfdump --uuid "$APP_BINARY" | cut -d ' ' -f 2)" == "$(xcrun dwarfdump --uuid "$DSYM" | cut -d ' ' -f 2)" ]] || {
  echo "dSYM does not match the app binary" >&2
  exit 1
}

rm -f "$ZIP_PATH" "$ZIP_PATH.sha256" "$DSYM_ZIP"
/usr/bin/ditto -c -k --keepParent "$DSYM" "$DSYM_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
(cd "$ROOT_DIR/dist" && /usr/bin/shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
/usr/bin/unzip -tq "$ZIP_PATH"

echo "Created $ZIP_PATH"
