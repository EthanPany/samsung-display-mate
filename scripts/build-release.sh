#!/bin/zsh
# Builds the ad-hoc signed release zip in dist/. Requires Xcode and xcodegen.
# Hardened runtime stays off here: without a Team ID, library validation stops the app loading its own framework.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-1.0.0}
xcodegen generate
rm -rf build/rel dist
xcodebuild build -project SamsungDisplayMate.xcodeproj -scheme SamsungDisplayMate -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/rel \
  MARKETING_VERSION="$VERSION" ENABLE_HARDENED_RUNTIME=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= OTHER_CODE_SIGN_FLAGS=--timestamp=none \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES COPY_PHASE_STRIP=YES
mkdir dist
ditto -c -k --keepParent "build/rel/Build/Products/Release/Samsung Display Mate.app" "dist/SamsungDisplayMate-$VERSION-arm64.zip"
shasum -a 256 dist/*.zip
