# 绿果视频 · 原生重写（native-rewrite 分支）

SwiftUI + AVFoundation + JavaScriptCore 的全量原生重写，与 Flutter 版同包名
`com.lvguo.video`，以便将来同签名覆盖安装、不丢数据。部署目标 iOS 26，
UI 使用系统原生液态玻璃（TabView 玻璃底栏 + glassEffect）。

## 一期骨架（本目录现状）

- `LvguoNative.xcodeproj`：文件系统同步组工程，源码在 `LvguoNative/` 下自动纳入。
- 5 页 TabView：首页 / 历史 / 资源 / 下载 / 我的（占位内容）。
- 首页与历史页有原生玻璃分段控件（站源 / 文件源）；首页有一张 glassEffect 玻璃卡片。
- 播放器：`Player/PlaybackEngine.swift`（AVPlayer + 卡顿/中断自动恢复，intentToPlay 门控）
  + `Player/PlayerView.swift`（AVPlayerViewController 包装，系统画中画）。
  资源页「测试播放」用公开测试流验证整条链路（含 headers 注入）。
- 模块：`Modules/ModuleRunner.swift`（JavaScriptCore 加载 JS、注入 lvguo 桥、
  调 main() 拿 JSON）；资源页「运行示例模块」可看运行结果。

## 已知限制 / 二期事项

- AVURLAsset 的 headers 只作用于首个请求；HLS 分片不继承，二期用
  AVAssetResourceLoaderDelegate 处理带头分片。
- httpGet 目前是同步占位实现（返回示例 JSON），二期换真实异步网络层。
- 数据迁移：原生版首次启动时读取旧 Flutter 版容器内数据
  （SharedPreferences plist、应用支持目录的本地库等），迁移源模块、历史、
  设置、文件源配置。覆盖安装保留容器是前提——同包名、同签名，工程里
  不要加任何改变容器身份的设置。
- 二期范围：模块系统完整移植（安装/存储/PlaybackPlan 解析）、文件源
  （WebDAV/FTP/HTTP + 天翼/移动 WebView 登录）、历史与数据层、下载。

## CI

`.github/workflows/build-ios.yml`（仅 native-rewrite 分支）：macOS 构建机
选最新 Xcode，xcodebuild 无签名构建，产物为未签名 IPA（artifact 下载）。
