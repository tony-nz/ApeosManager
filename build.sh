#!/bin/bash
# Builds and signs Apeos Manager.
#
# Signing matters beyond distribution: keychain access control is bound to the app's
# code identity. An unsigned binary has none, so macOS treats every rebuild as a
# different app and previously saved printer passwords become unreadable. Signing with
# the same certificate and identifier each time keeps them.
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
IDENTITY="${APEOS_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  echo "Set APEOS_SIGN_IDENTITY to your codesigning identity, e.g."
  echo "  export APEOS_SIGN_IDENTITY=\"Apple Development: Your Name (TEAMID)\""
  echo "  security find-identity -v -p codesigning   # to list yours"
  exit 1
fi
APP=./build/Build/Products/Debug/ApeosManager.app

xcodegen generate >/dev/null
xcodebuild -project ApeosManager.xcodeproj -scheme ApeosManager -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build "$@" | grep -E 'error:|warning: no rule|BUILD (SUCCEEDED|FAILED)' || true

codesign --force --deep --sign "$IDENTITY" \
         --identifier nz.co.myers.ApeosManager \
         --options runtime "$APP" 2>&1 | sed 's/^/  codesign: /'
codesign -dv "$APP" 2>&1 | grep -E 'Authority|Identifier=' | sed 's/^/  /'
echo "built: $APP"
