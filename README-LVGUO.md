# 绿果视频

影视聚合播放器（Flutter 多端应用），支持画中画（PiP）播放。

> 本项目是 [Xanerix/guoapp](https://github.com/Xanerix/guoapp)（小果影视）的
> 改名衍生版。原项目以 **GNU GPLv3** 开源，衍生版同样遵循 GPLv3；
> 原作者版权声明与 `LICENSE` 文件保持不变。CHANGELOG.md 保留为上游
> 历史记录。

## 与上游相比改了什么

- 应用名：**小果影视 → 绿果视频**（`lib/app_build.dart`、`scripts/app_build.py`、
  Android / iOS / macOS / Windows 各端配置、README、DEVELOPMENT.md）。
- 包名：`com.guoapp.app` → **`com.lvguo.video`**（iOS、macOS、Android 默认
  applicationId、Windows；Android 的 `namespace` 仍为 `com.guoapp`，
  仅影响 R 类包名，不影响安装与显示）。
- 图标：整套应用图标由蓝灰色改为绿色（iOS AppIcon、macOS 图标、
  Android launcher 图标均已重生成）。
- 上游的发布流程（`.github/workflows/build.yml`，需要私有站源仓库、
  Android 签名 Secrets、只能从 main 发布）已删除，改为本文件下面的
  轻量工作流，只做未签名 iOS 包。
- **液态玻璃风格**（见下）：新增 `lib/ui/widgets/liquid_glass.dart`
  （`LiquidGlass` / `LiquidGlassIconButton`），底部导航栏、横屏播放器
  控制按钮与底部控制条、播放器底部弹窗已改为玻璃质感。
- 画中画：**上游已自带，无需新增**（见下）。

## 液态玻璃（Liquid Glass）风格

目标是 iOS 26 的液态玻璃质感。**如实说明：这不是原生 Liquid Glass，液态玻璃是 Flutter 模拟效果。**
Flutter 3.47 没有暴露 iOS 26 的原生 Liquid Glass API（SwiftUI
`.glassEffect()`），原生层也没有可直接接的现成接口；本项目用玻璃拟态
模拟最接近的效果，不引入新依赖：

- 实现：`lib/ui/widgets/liquid_glass.dart` —— `ClipRRect` 圆角 +
  `BackdropFilter` 实时模糊（sigma 18，按钮 14）+ 半透明渐变
  （顶部高光到底部渐暗）+ 1px 白色细边框 + 柔和投影；深色/浅色主题
  自动切换透明度。
- 已应用的位置：
  - 底部导航栏（`lib/ui/shell/app_shell.dart`）：整条导航包在顶部圆角
    的玻璃条里，`NavigationBar` 本身背景设为透明。
  - 播放器控制按钮（`lib/ui/player/landscape_player_page.dart` 的
    `_icon`）：返回、小窗、设置、全屏等按钮均为玻璃圆钮。
  - 横屏播放器底部控制条（同文件 `_miniControls`）：进度条 + 控制行
    包在玻璃胶囊里。
  - 播放器底部弹窗（`lib/ui/player/playback_sheets.dart` 的
    `showPlayerSheet`）：弹窗背景透明，内容包在顶部圆角的玻璃面板里。
  - v1.0.0 扩展：顶部 AppBar 全局半透明（`lib/ui/theme/app_theme.dart`）、
    搜索框（`lib/ui/widgets/search_field.dart`）、首页海报卡片
    （`lib/ui/widgets/drama_tile.dart`）、选择面板/底部弹窗
    （`lib/ui/widgets/choice_panel.dart`）、设置页分组卡片
    （`lib/ui/widgets/group_card.dart`）。只换容器质感，配色与布局结构不变。
- 未改动：播放流程、画中画逻辑、按钮的点击行为与尺寸均未动，只换了
  视觉包装；竖屏播放器的图标按钮未包玻璃（与横屏实现不同，后续可按
  同样方式包）。

## 画中画（PiP）是怎么实现的

- Dart 层：`lib/picture_in_picture.dart`（`PictureInPicture` 单例，
  MethodChannel `duanju/ios_pip`）；播放页 `lib/ui/player/playback_page.dart`
  在播放时持续 `update()` 上报播放器句柄与播放状态，退出播放时 `clear()`。
- 原生层：`packages/media_kit_video/ios/Classes/plugin/common/MediaKitVideoPlugin.swift`
  用 `AVPictureInPictureController.isPictureInPictureSupported()` 创建 PiP
  控制器，把视频帧送进 PiP 画面，支持开始 / 停止 / 自动进入。
- 播放器里本来就有明确的画中画按钮：横屏与竖屏播放控制条上的
  **「小窗」**（`Icons.picture_in_picture_alt_rounded`），点一下进画中画，
  再点一下退出；设置里还有「自动进入画中画」开关
  （`playbackPreferences.autoPictureInPicture`），切后台时自动进小窗。
- `ios/Runner/Info.plist` 已有 `UIBackgroundModes: audio`，画中画在后台
  继续播声音的必要条件已满足。

## 如何拿到 IPA（两种办法）

### 办法一：GitHub Actions 自动编（推荐）

1. 把本项目推到你自己的 GitHub 仓库（例如 `lvguo-video`）的 `main` 分支。
2. 打开仓库的 **Actions → Build iOS IPA (unsigned) → Run workflow**
   （推到 `main` 也会自动触发）。
3. 等跑完（约 20–40 分钟），在运行详情页下载 artifact
   **`lvguo-ios-unsigned`**，里面是
   `lvguo-<版本>-ios-unsigned.ipa`（未签名）。
4. 用自己的 Apple ID 通过 AltStore / ESign / Scarlet 自签安装。

注意：这个自动构建**不带内置站源模块**（上游 CI 会从私有仓库检出
红果模块一起打包，本项目没有那个仓库）。装好后首次打开没有片源，
需要在应用内的模块商店里添加站源模块。

### 办法二：在 Mac 上本地编

需要 macOS + 完整 Xcode + Flutter 3.47.9 + Go 1.24+ + CocoaPods：

```sh
python scripts/build_ios.py
```

产物在 `dist/ios/lvguo-<版本>-ios-unsigned.ipa`。该脚本会先把 Go
原生核心编成 `ios/DuanjuCore/DuanjuCore.xcframework`，再跑
`flutter build ios --release --no-codesign` 并打包、校验未签名状态。
只想编核心可用 `python scripts/build_ios.py --core-only`。
有自己的签名时可传 `--export-options` 导出已签名 IPA。

## 开发相关

上游文档仍适用：`DEVELOPMENT.md`（已同步改名与包名）、
`CONTRIBUTING.md`。Dart 代码用 `dart analyze`，Go 核心用
`go test ./...`（在 `native/` 目录下）。

## 二进制资源说明（.b64）

推送到 GitHub 的途径只接受 UTF-8 文本文件，所以 91 个二进制资源（PNG 图标、弹幕 emoji、.ico）以 base64 文本形式存为 `<原路径>.b64`。检出后先跑一次 `python3 scripts/decode_assets.py` 还原成原文件再编译；GitHub Actions 工作流里已经自动跑了这一步，不用手动处理。
