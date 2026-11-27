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
  # 已知形态（run 45966946541 诊断 + 45968109032 复证）：
  # -sdk 构建下 SPM 包目标的全部产物落在带 -iphoneos 后缀
  # 的目录里，而应用侧按 SPM 集成约定计算的路径不带后缀
  # ——包本身编译无误，缺的只是路径别名。用符号链接把
  # 不带后缀的路径桥接到实际产物目录后重跑构建（包目标
  # 已最新，第二遍只补链接与应用组装）：
  #   Build/Products/Release            → Release-iphoneos
  #   Intermediates.noindex/{KSPlayer,FFmpegKit}.build/Release
  #                                       → Release-iphoneos
  DD="build/DerivedData/Build"
  if [ -d "$DD/Products/Release-iphoneos" ]; then
    ln -sfn Release-iphoneos "$DD/Products/Release"
    for B in KSPlayer FFmpegKit; do
      if [ -d "$DD/Intermediates.noindex/$B.build/Release-iphoneos" ]; then
        ln -sfn Release-iphoneos "$DD/Intermediates.noindex/$B.build/Release"
      fi
    done
    echo "error: DIAG bridged: products=$(readlink "$DD/Products/Release" 2>/dev/null) ksplayer=$(readlink "$DD/Intermediates.noindex/KSPlayer.build/Release" 2>/dev/null) ffmpegkit=$(readlink "$DD/Intermediates.noindex/FFmpegKit.build/Release" 2>/dev/null)" | tee -a build.log
    xcodebuild build "${BUILD_ARGS[@]}" 2>&1 | tee -a build.log
    BUILD_RC=${PIPESTATUS[0]}
  fi
fi
exit $BUILD_RC
