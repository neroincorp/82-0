#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build Payload 17-0-adhoc.ipa

xcodebuild \
  -project SeventeenZero.xcodeproj \
  -scheme SeventeenZero \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  clean build

APP='build/Build/Products/Release-iphoneos/SeventeenZero.app'
PLIST="$APP/Info.plist"

[ -d "$APP" ] || { echo "ERROR: Missing $APP"; exit 1; }
[ -f "$PLIST" ] || { echo 'ERROR: Missing built Info.plist'; exit 1; }

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
[ -n "$BUNDLE_ID" ] || { echo 'ERROR: Missing CFBundleIdentifier'; exit 1; }
[ -n "$EXECUTABLE" ] || { echo 'ERROR: Missing CFBundleExecutable'; exit 1; }
[ -f "$APP/$EXECUTABLE" ] || { echo "ERROR: Missing executable $APP/$EXECUTABLE"; exit 1; }

rm -rf "$APP/_CodeSignature"
rm -f "$APP/embedded.mobileprovision"
xattr -cr "$APP" || true

if [ -d "$APP/Frameworks" ]; then
  find "$APP/Frameworks" -type d -name '*.framework' -print0 | while IFS= read -r -d '' ITEM; do
    /usr/bin/codesign --force --sign - --timestamp=none "$ITEM"
  done
  find "$APP/Frameworks" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' ITEM; do
    /usr/bin/codesign --force --sign - --timestamp=none "$ITEM"
  done
fi
if [ -d "$APP/PlugIns" ]; then
  find "$APP/PlugIns" -type d -name '*.appex' -print0 | while IFS= read -r -d '' ITEM; do
    /usr/bin/codesign --force --sign - --timestamp=none "$ITEM"
  done
fi

/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP"

rm -rf Payload
mkdir Payload
cp -R "$APP" Payload/
xattr -cr Payload || true
export COPYFILE_DISABLE=1
/usr/bin/zip -qry 17-0-adhoc.ipa Payload
/usr/bin/unzip -t 17-0-adhoc.ipa

/usr/bin/unzip -Z1 17-0-adhoc.ipa | grep -q '^Payload/SeventeenZero.app/Info.plist$'
/usr/bin/unzip -Z1 17-0-adhoc.ipa | grep -q '^Payload/SeventeenZero.app/_CodeSignature/CodeResources$'
/usr/bin/unzip -Z1 17-0-adhoc.ipa | grep -q '^Payload/SeventeenZero.app/SeventeenZero$'

rm -rf Payload
echo "Created: 17-0-adhoc.ipa"
