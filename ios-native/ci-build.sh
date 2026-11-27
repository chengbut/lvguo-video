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
# Package.swift 按同级目录是否存在 FFmpegKit checkout 决定用
# 本地路径还是 URL 依赖，先解析把 checkouts 铺满再构建。
xcodebuild -resolvePackageDependencies \
  -project LvguoNative.xcodeproj \
  -scheme LvguoNative \
  -derivedDataPath build/DerivedData \
  -scmProvider system
# No -destination: generic/platform=iOS 在本 runner 上找不到
# destination（exit 70，run 45966325409 实测）；-sdk iphoneos
# 是此前 20 次成功构建的原配。
BUILD_ARGS=(
  -project LvguoNative.xcodeproj
  -scheme LvguoNative
  -configuration Release
  -sdk iphoneos
  -derivedDataPath build/DerivedData
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
)
xcodebuild build "${BUILD_ARGS[@]}" 2>&1 | tee build.log
BUILD_RC=${PIPESTATUS[0]}
if [ "$BUILD_RC" != "0" ] && grep -q "Build input files cannot be found" build.log; then
  # 已知形态（run 45966946541 诊断实测）：-sdk 构建下 SPM 包
  # 目标的合并 .o 落在 Release-iphoneos/，而应用的链接阶段
  # 按 SPM 集成约定去 Release/ 找——包本身编译无误，只差
  # 这一层路径。把 .o 桥接过去后重跑构建（包目标已最新，
  # 第二遍只补链接与应用组装）。
  PROD="build/DerivedData/Build/Products"
  if [ -d "$PROD/Release-iphoneos" ]; then
    mkdir -p "$PROD/Release"
    cp -f "$PROD"/Release-iphoneos/*.o "$PROD/Release/" 2>/dev/null || true
    echo "error: DIAG bridged-o: $(ls "$PROD/Release" 2>/dev/null | tr '\n' ' ')" | tee -a build.log
    xcodebuild build "${BUILD_ARGS[@]}" 2>&1 | tee -a build.log
    BUILD_RC=${PIPESTATUS[0]}
  fi
fi
exit $BUILD_RC
