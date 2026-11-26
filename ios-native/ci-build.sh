#!/bin/bash
# CI build script for the native iOS app (unsigned).
# Called by .github/workflows/build-ios.yml with working-directory ios-native.
# Kept in the repo (not in the workflow YAML) so the build command can be
# iterated through the contents API — workflow files cannot.
set -o pipefail
cd "$(dirname "$0")"
# No -destination: with -sdk iphoneos, xcodebuild builds for the SDK's
# default device destination. Passing 'generic/platform=iOS' alongside
# -sdk made xcodebuild exit 70 ("Unable to find a destination") on the
# macos-26 runner (run 45869500692).
xcodebuild build \
  -project LvguoNative.xcodeproj \
  -scheme LvguoNative \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  2>&1 | tee build.log
