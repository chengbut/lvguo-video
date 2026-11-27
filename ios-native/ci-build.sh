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
# 本地路径还是 URL 依赖，冷 DerivedData 下解析与构建两次求值
# 结果不一致时，构建图里的包目标不会被调度，最终报
# "Build input files cannot be found: KSPlayer.o"（run
# 45964085342 实测）。
xcodebuild -resolvePackageDependencies \
  -project LvguoNative.xcodeproj \
  -scheme LvguoNative \
  -derivedDataPath build/DerivedData \
  -scmProvider system
# 临时诊断（定位 SPM 包目标未调度问题）：以 error: 前缀写进
# build.log，借工作流的注解步骤把 runner 上的解析状态带出来
{
  echo "error: DIAG checkouts: $(ls build/DerivedData/SourcePackages/checkouts 2>/dev/null | tr '\n' ' ')"
  echo "error: DIAG artifacts: $(ls build/DerivedData/SourcePackages/artifacts 2>/dev/null | tr '\n' ' ')"
  echo "error: DIAG resolved: $(python3 -c "
import json
try:
    d = json.load(open('build/DerivedData/SourcePackages/workspace-state.json'))
    pins = []
    for p in d.get('object', {}).get('dependencies', []):
        pkg = p.get('packageRef', {})
        st = p.get('state', {})
        pins.append(pkg.get('identity', '?') + '=' + str(st.get('version') or st.get('branch') or st.get('revision', '')[:8]))
    print(' '.join(pins))
except Exception as e:
    print('workspace-state unreadable:', e)
" 2>/dev/null)"
} 2>&1 | tee build.log
# No -destination: generic/platform=iOS 在本 runner 上找不到
# destination（exit 70，run 45966325409 实测）；-sdk iphoneos
# 是此前 20 次成功构建的原配。
xcodebuild build \
  -project LvguoNative.xcodeproj \
  -scheme LvguoNative \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  2>&1 | tee -a build.log
BUILD_RC=${PIPESTATUS[0]}
if [ "$BUILD_RC" != "0" ]; then
  {
    echo "error: DIAG find-o: $(find build/DerivedData -name 'KSPlayer.o' -o -name 'DisplayCriteria.o' -o -name 'FFmpegKit.o' 2>/dev/null | head -4 | tr '\n' ' ')"
    echo "error: DIAG products: $(ls build/DerivedData/Build/Products 2>/dev/null | tr '\n' ' ')"
    echo "error: DIAG inter-ksplayer: $(find build/DerivedData -type d -name 'KSPlayer.build' 2>/dev/null | head -3 | tr '\n' ' ')"
  } 2>&1 | tee -a build.log
fi
exit $BUILD_RC
