# 绿果视频 · 原生重写（native-rewrite 分支）

SwiftUI + AVFoundation + JavaScriptCore 的全量原生重写，与 Flutter 版同包名
`com.lvguo.video`，以便将来同签名覆盖安装、不丢数据。部署目标 iOS 26，
UI 使用系统原生液态玻璃（TabView 玻璃底栏 + glassEffect）。

## 工程结构

- `LvguoNative.xcodeproj`：文件系统同步组工程，源码在 `LvguoNative/` 下自动纳入。
- 5 页 TabView：首页 / 历史 / 资源 / 下载 / 我的。
- 播放器：`Player/PlaybackEngine.swift`（AVPlayer + 卡顿/中断自动恢复，intentToPlay 门控）
  + `Player/PlayerView.swift`（AVPlayerViewController 包装，系统画中画）。
- 模块系统：`Modules/`，协议与 Flutter 版 Go 核心（native/core）完全一致，
  现有 JS 模块可原样运行（见下）。

## 二期 A 段：模块系统（已完成）

主链路：资源页装模块 → 首页（站源模式）分类+列表 → 详情页选集 →
resolveMedia 拿播放计划 → PlayerPage 用 AVPlayer 播放（headers 注入）。

- `ModuleManifest.swift`：清单模型与校验，规则/报错文案与 Go `parseModuleManifest`
  一致（id 正则、runtime=js、api=1、adult 必填、能力白名单、mediaAuth 约束等）。
- `ModuleRunner.swift`：JSContext 运行时。模块代码按 Go 的方式包装
  `(function(module, exports, host) { … })`，调用走同款 invoker
  （参数 JSON 编码、结果 JSON 回收、Promise 结果报错「不能是异步函数」）。
  桥 `host` 与 Go hostAPI 对齐：fetch / fetchText / fetchPlaylist / parseUrl /
  resolveUrl / loadState / saveState / cacheGet / cacheSet / log / sleep /
  dramaId / chapterId / 字节与编码工具（utf8/hex/base64）/ 哈希
  （md5/sha256/sha512）/ aesCbc 加解密（无填充，与 Go 一致）/ randomBytes /
  preserveIntegers（BigInt 判定超精度整数）等。网络在桥内同步阻塞
  （URLSession + 信号量），与 goja 的同步语义一致；清单 hosts 白名单在
  每次请求前校验（`*.example.com` 后缀匹配规则同 Go）。
- `ModuleProvider.swift`：categories / catalogPage / search / detail /
  resolveMedia / account 的类型化封装；数据结构按 Go models 的宽容解析
  （封面/集数多键名兼容、EpisodeString 规则等）。
- `ModuleStore.swift`：模块安装与管理（URL 下载 zip 包、包内根目录或
  唯一一级子目录两种布局、8MB/64KB/4MB 上限同 Go）、启用/停用/设为当前/卸载。
- 内置示例模块 `SampleModule.swift`：与 Flutter 版 jsexample 内容一致
  （假数据、不联网），资源页可一键安装验证链路；其 resolveMedia 按原样
  抛错「只有假数据，不能播放」。

### 数据存储格式（三期数据迁移预留）

全部数据在 App 容器 `Application Support/LvguoNative/` 下：

```
LvguoNative/
  library.json                 模块库索引：{"current": "<id>", "disabled": ["<id>", …]}
  modules/<id>/manifest.json   模块清单（原文）
  modules/<id>/main.js         模块脚本（原文）
  module-state/module-<id>-<name>   host.loadState/saveState 的持久化值（原文字符串）
```

- `modules/<id>/` 布局与 Go 版 `<dataDir>/modules/<id>/` 一致，三期迁移
  Flutter 版数据时可直接对位拷贝。
- 模块内存缓存（cacheGet/cacheSet）不落盘，与 Go 版一致。
- 三期再加：历史、设置、文件源配置，以及首次启动从旧 Flutter 容器迁移。

### 与 Go 版桥接面的差异（已知）

- 实例数：Go 最多 4 个模块实例并行，原生版每模块 1 个串行运行时；
  模块函数内的并发调用会被串行化（语义不变，极端场景下更慢）。
- `fetch` 的 `ticket`（reserve 预留）与限流/重试体系未实现：reserve 直接
  抛错；`background` / `direct` 字段接受但忽略；重定向用 URLSession 默认策略。
- 未实现：`parseHtml`、`gzip/gunzip`、`aesGcmSeal/Open`、`ecdhP256*`、
  `hkdfSha256`、`prepareWebMedia`（原样返回）、`preferredSite`（返回空）、
  `catalogContext`（返回 `{more:false, background:false}`）、`isKnown`（false）。
  用到这些的模块会在对应调用处抛错或走降级路径，错误会透出到 UI。
- `resolveMedia` 返回纯 m3u8 文本（playlist）时，Go 版经本地代理生成 URL，
  原生版暂不能直接播放，详情页会明确提示（已知限制）。
- AVURLAsset 的 headers 只作用于首个请求；HLS 分片不继承（沿用一期结论，
  后续可用 AVAssetResourceLoaderDelegate 处理带头分片）。

## 一期骨架说明

- 首页与历史页有原生玻璃分段控件（站源 / 文件源）；首页站源侧已接真实
  模块数据，文件源侧与历史/下载/我的仍为占位（二期 B 段：文件源、历史与
  数据层、下载、首次启动数据迁移）。
- 数据迁移：原生版首次启动时读取旧 Flutter 版容器内数据
  （SharedPreferences plist、应用支持目录的本地库等），迁移源模块、历史、
  设置、文件源配置。覆盖安装保留容器是前提——同包名、同签名，工程里
  不要加任何改变容器身份的设置。

## CI

`.github/workflows/build-ios.yml`（仅 native-rewrite 分支）：macOS 构建机
选最新 Xcode，运行 `ios-native/ci-build.sh` 无签名构建，产物为未签名 IPA
（artifact 下载）。
