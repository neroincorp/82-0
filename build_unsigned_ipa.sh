#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build Payload 17-0-unsigned.ipa
xcodebuild \
  -project SeventeenZero.xcodeproj \
  -target SeventeenZero \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build
APP="build/Build/Products/Release-iphoneos/SeventeenZero.app"
if [ ! -d "$APP" ]; then
  echo "Could not find built app at $APP"
  exit 1
fi
mkdir Payload
cp -R "$APP" Payload/
/usr/bin/zip -qry 17-0-unsigned.ipa Payload
rm -rf Payload
echo "Created: 17-0-unsigned.ipa"
