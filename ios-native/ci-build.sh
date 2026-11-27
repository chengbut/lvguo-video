#!/bin/bash
# CI build script for the native iOS app (unsigned).
# Called by .github/workflows/build-ios.yml with working-directory ios-native.
# Kept in the repo (not in the workflow YAML) so the build command can be
# iterated through the contents API — workflow files cannot.
set -o pipefail
cd "$(dirname "$0")"
# Binary assets (AppIcon PNGs) travel as .b64 text in git; decode first.
python3 scripts/decode_assets.py
# 先单独做一次依赖解析（与 Xcode GUI 的流程一致）：KSPlayer 的
# Package.swift 按同级目录是否存在 FFmpegKit  checkout 决定用
# 本地路径还是 URL 依赖，冷 DerivedData 下解析与构建两次求值
# 结果不一致时，构建图里的包目标不会被调度，最终报
# "Build input files cannot be found: KSPlayer.o"（run
# 45964085342 实测）。先解析把 checkouts 铺满，再构建。
xcodebuild -resolvePackageDependencies \
  -project LvguoNative.xcodeproj \
  -scheme LvguoNative \
  -derivedDataPath build/DerivedData \
  -scmProvider system
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
