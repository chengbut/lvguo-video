# 绿果视频 · 原生重写（native-rewrite 分支）

SwiftUI + AVFoundation + JavaScriptCore 的全量原生重写，与 Flutter 版同包名
`com.lvguo.video`，以便将来同签名覆盖安装、不丢数据。部署目标 iOS 26，
UI 使用系统原生液态玻璃（TabView 玻璃底栏 + glassEffect）。

总原则（用户 2026-11-27 定）：先照搬、再改——功能、条目、布局结构、
行为与 Flutter 版对齐是硬要求；控件外观用 SwiftUI/UIKit 系统控件即可，
不逐像素复刻 Flutter 自绘样式（用户 2026-11-27 补充尺度）。

## 工程结构

- `LvguoNative.xcodeproj`：文件系统同步组工程，源码在 `LvguoNative/` 下自动纳入。
- 5 页 TabView：首页 / 历史 / 资源 / 下载 / 我的。
- 播放器：`Player/PlaybackEngine.swift`（AVPlayer + 资源代理 + 恢复预算）
  + `Player/PlayerView.swift`（AVPlayerLayer 单一控件层 + 自绘控件 +
  AVPictureInPictureController 系统画中画）。
- 模块系统：`Modules/`，协议与 Flutter 版 Go 核心（native/core）完全一致，
  现有 JS 模块可原样运行。

## 修复轮 3（2026-11-27）：取流 TLS 失败诊断 + 页面布局结构修正

### TLS 差异表（Go 核心 vs 原生 URLSession）

| 维度 | Go 核心（Flutter 版，取流正常） | 原生 URLSession（修复轮 3 前） |
|---|---|---|
| 传输栈 | crypto/tls（模块 fetch 走 d.client；direct 时走 directClient） | CFNetwork（系统 TLS），`URLSession(.default)` |
| TLS 版本 | MinVersion TLS 1.2，最高 1.3 | 系统默认（1.0–1.3 协商） |
| ALPN | http.Transport 恒带 NextProtos（h2、http/1.1） | 系统决定，应用层不可见、不可控 |
| 证书校验 | 标准校验（InsecureSkipVerify 仅当配置 InsecureTLS） | 标准校验 |
| 浏览器指纹通道 | 清单声明 `browserFingerprint: true` 的模块，其 baseURL 主机（+aliases）的 GET/HEAD 走 uTLS Chrome 150 指纹客户端（bogdanfinn/tls-client，随机扩展序、禁 HTTP/3、自带 cookie jar） | 无（清单未解析该字段，iOS 无公开 TLS 指纹控制 API） |
| DNS 兜底 | CDN 保护主机的 GET/HEAD 失败时经 DoH（alidns/google）换地址钉连重试（cdnTransport） | 系统解析，无兜底 |
| 代理 | proxyRouter（系统/手动） | 系统代理（.default 配置） |
| 超时/重试 | 客户端 45s；fetchText 多候选轮换、模块层整链重试 | 单次尝试，失败即回 |
| 请求头 | 模块头逐字 Set（Go 仅代管 Host/Content-Length/Connection） | setValue 设置；Host/Content-Length/Connection 同样由 CFNetwork 代管（等价） |
| Cookie | 主客户端无 jar（浏览器通道有） | .default 共享 cookie 存储 |

### 诊断结论（握手级探测，未调用任何业务接口）

对模块取流端点（api5-normal-sinfonlineb.fqnovel.com、reading.snssdk.com，
经本机出口 CONNECT 隧道做纯 TLS 握手探测，www.apple.com 作对照）：

1. **不带 ALPN 的 ClientHello 被网关黑洞**：两端点均握手无响应直至
   超时；对照组 apple.com 无 ALPN 正常完成。带 ALPN（h2/http/1.1
   任意）时两端点 TLS 1.2/1.3 均可握手，服务端恒选 http/1.1，
   重复 8 次全成功。
2. **真机失败是间歇性的**：同一截图里「播放器接口」分支的设备注册
   已通过 TLS（失败在「未返回设备号」的业务层），而签名/App 分支
   报 -1200——不是全量封杀，更像 DSA CDN 边缘节点对协商形态的
   容忍度不一致（该域名 CNAME 链进 `*.c.dsa.cdnbuild.net` 的
   L7 调度，逐次解析落点不同）。
3. Go 在同机同网正常的原因：ALPN 恒开、模块层整链重试、CDN 通道
   的 DoH 换址重试——单次握手落到坏节点也会被后续重试绕开；
   原生旧实现单次尝试、无任何连接级重试，一次落空即整链失败。

### 本轮修复（只动 host 传输层，通用机制，无模块特判）

- `ModuleHostBridge.perform` 改为**传输变体阶梯**：标准配置 →
  全新临时会话（新连接/新 DNS 选择/不复用连接池）→ 临时会话 +
  TLS 最高 1.2；只对「请求字节未送达服务端」的失败换变体重试
  （握手失败 -1200、连不上 -1004、DNS -1003/-1006 恒重试；
  超时 -1001、连接丢失 -1005 只重试 GET/HEAD），总时长仍受
  原 timeout + 10 秒约束；成功变体按主机记住（provider 级共享），
  后续请求直达。fetch/fetchText/fetchPlaylist/prepareWebMedia
  共用此入口，一处修复全链生效。
- 失败文案带上 NSURLError 错误码（如「A TLS error caused the
  secure connection to fail.（-1200）」），下一轮真机截图可直接
  定位失败类别；诊断日志只记主机名与错误码，不记 URL/参数。
- 若真机复测仍全线 -1200，则证据指向服务端按 TLS 指纹拦截
  CFNetwork——iOS 不暴露 ClientHello 定制 API，host 层无解，
  届时需另行评估内置第三方 TLS 栈（不在本轮范围）。

### 布局修正（逐项）

- 详情页：加 `.toolbar(.hidden, for: .tabBar)` 全屏 push，
  消除底部胶囊与 tab bar 双层叠加（Flutter 详情在壳外全屏）；
  错误卡改可折叠（默认首个失败原因，展开看全文，原文不删）。
- 播放页 chrome 按真实安全区落位（旧版整层 ignoresSafeArea +
  顶 10pt/底 10pt 写死边距，顶栏撞灵动岛、底栏压 Home 指示条）：
  顶栏 top = 安全区顶、间距 12→8 对齐 Flutter header；渐变罩
  改全出血独立层（竖屏 130/220、横屏 110/150，对齐两页 _Shade）。
- 竖屏底部按 Flutter 竖屏页重构：玻璃控制块（圆角 20，控制行
  只留上下集/播放/时间/倍速/选集 + 进度行）+ 独立集数条
  （选集入口带当前集、定时停止、小窗）；旧版十控件挤一行消除。
  清晰度/画面比例仍在设置面板，功能无删减。
- 暂停标记：竖屏改屏幕中央 72pt 圆钮（Flutter 竖屏页），
  横屏保留右下 68pt（右 20/底 92）。
- 锁定态锁钮：竖屏改右上角（安全区顶 + 6、右 12，对齐
  PlayerLockOverlay 竖屏 alignments），旧版落在屏幕正中；
  横屏保持左侧居中。
- 提示徽章：倍速徽章 top 改安全区顶 + 76（Flutter 竖屏页），
  toast 悬于底部控件块上方（安全区底 + 132）。
- 液态玻璃补齐（用户 2026-11-27 追加：能用原生液态玻璃的
  地方要用）：暂停钮（竖屏中央/横屏右下）改 glassEffect 玻璃
  圆钮、竖屏集数条改玻璃胶囊、播放设置/选集 sheet 背景改
  原生玻璃材质（presentationBackground + List 底色让出）；
  顶栏/锁钮原本就是系统玻璃钮，详情页头部/胶囊/错误卡/选集
  原本就是 glassEffect，未动。功能与布局对位不变。

## 全量对齐表（2026-11-27 修复轮 3 结束时状态）

状态含义：**已对齐** = 与 Flutter 版行为一致；**本轮补齐** = 本轮
（修复轮 2）新补上；**仍缺** = 未实现，后面括号里是具体技术原因。

### 播放页（以 Flutter PlayerSurface 为唯一规格）

| 条目 | 状态 | 说明 |
|---|---|---|
| 控件层 | 本轮补齐 | 旧版 AVPlayerViewController 自带控件与自绘顶栏叠加（左上角控键重叠的元凶）已废弃；改为 AVPlayerLayer + 单一自绘控件层 |
| 顶部栏 | 本轮补齐 | 返回玻璃圆钮 + 剧名（17pt semibold，不带集号）+ 画中画钮 + 设置齿轮；无标题玻璃胶囊；修复轮 3：整层改按真实安全区落位（top = 安全区顶，元素间距 8），旧版 ignoresSafeArea + 写死 10pt 边距会撞灵动岛 |
| 状态行（网速/时钟） | 本轮补齐 | 全屏控件可见时按偏好显示：网速取 accessLog 观测码率（KB/s、MB/s），时钟为 HH:mm 墙钟 |
| 点按显隐 | 本轮补齐 | 单击 300ms 延迟切换（等双击判定），播放中 3 秒自动隐藏，暂停/卡顿/未就绪常显 |
| 双击快进/快退 | 本轮补齐 | 左右四分之一区 ±10 秒连击累积（700ms 提交窗口），徽标「快进/快退 N 秒」；中区双击切播放；受 doubleTapSeek 偏好开关 |
| 长按倍速 | 本轮补齐 | 长按以 boostSpeed（默认 2.0x）播放，徽标「倍速播放中」，松手恢复 |
| 横滑进度 | 本轮补齐 | 全宽跨度 min(时长,120s)，徽标「目标 / 时长」，松手 seek |
| 竖滑亮度/音量 | 本轮补齐 | 左半亮度（UIScreen）、右半音量（系统音量视图滑杆），徽标为图标 + 120px 进度条；swipeLevels 关闭且 swipeEpisodes 开启时竖滑切集（60pt 阈值，文案「松手播放下一集/上一集」「已经是第一/最后一集」与 Flutter 一致） |
| 底部进度条 | 本轮补齐 | 渐变罩（修复轮 3 改全出血独立层：竖屏高 220、横屏高 150，透明→78% 黑；顶罩竖屏 130/横屏 110）上：滑杆（主色）+ 缓冲位置副轨 + 时间 `位置 / 时长`（13px）；底栏本体按安全区底落位，不再压 Home 指示条 |
| 底部工具栏 | 本轮补齐 | 横屏：上一集 / 播放暂停（48 槽 30 图标）/ 下一集 / 时间 / 清晰度菜单 / 倍速菜单（粗体）/ 画面比例菜单 / 选集 / 定时停止菜单 / 画中画。修复轮 3 竖屏按 Flutter 竖屏页拆分：玻璃控制块（圆角 20）只放上下集/播放/时间/倍速/选集 + 进度行，下方独立集数条放选集入口/定时/小窗；清晰度/画面比例在设置面板 |
| 选集入口 | 本轮补齐 | 工具栏选集钮打开选集面板（网格，当前集高亮），对齐 Flutter 横屏侧栏 EpisodeGrid |
| 锁定 | 本轮补齐 | 中左侧锁钮；锁定后只剩锁图标（点屏探出），文案「已锁定，点屏幕显示锁图标」「已锁定，点击锁图标解锁」「已解锁」与 Flutter 一致；修复轮 3：锁定态探出位置竖屏改右上角（安全区顶 + 6、右 12，对齐 PlayerLockOverlay 竖屏 alignments），旧版落在屏幕正中 |
| 暂停标记 | 本轮补齐 | 横屏 68pt 玻璃圆钮 + 播放图标，右 20 / 底 92；修复轮 3：竖屏改屏幕中央 72pt 玻璃圆钮（对齐 Flutter 竖屏页中央大播放钮，材质改原生液态玻璃） |
| 卡顿指示 | 本轮补齐 | 已就绪且卡顿时中央只转圈（对齐 Flutter stall 态） |
| 加载状态 | 本轮补齐 | 半透明黑遮罩 + 转圈 + 加载文案（「正在准备播放」/恢复时「正在重新获取播放地址」「正在切换备用线路」，与 Flutter 一致） |
| 失败状态 | 本轮补齐 | 90% 黑遮罩 + 标题「暂时无法播放」+ 症状文案与原始错误 + 「重试」（本地为「重试本地播放」）/「从头播放」（进度 > 0 时）/「改为在线播放」（本地失败且有在线回退时），与 Flutter 一致 |
| 加载超时 | 本轮补齐 | 30 秒未就绪且无进度 → 超时失败进错误状态，不再无限「加载中」 |
| 错误原文透出 | 本轮补齐 | AVPlayerItem 的系统错误原文（含错误日志 errorComment）进失败文案；切集取址失败的模块原始错误以 toast 透出（旧版 resolveRequest 静默吞错已修） |
| 画中画 | 已对齐 | AVPictureInPictureController（系统托管）；自动画中画偏好（回后台自动进 PiP）；PiP 中退出页面由 PlaybackKeepAlive 托管引擎续播，对齐 Flutter 页面 pop 后 PlaybackHost 接管 |
| 全屏按钮 | 已对齐（结构等效） | 原生播放页本身即全屏呈现，Flutter 的「进全屏」动作在此结构下恒成立，未摆按钮 |
| 竖屏样式页 | 仍缺（结构差异） | Flutter 竖屏页是纵滑切集 PageView + 下半部剧目信息区，原生播放页是单一全屏页；修复轮 3 已把竖屏 chrome 的位置/安全区逐项对位（顶栏、玻璃控制块 + 集数条、中央暂停钮、右上锁钮、徽章位置），纵滑切集与竖屏页下方的剧目信息区未移植 |
| 弹幕 | 已对齐（同为不支持） | Flutter 的 danmakuSupported 只认内置 SourceSite 注册表，JS 模块源恒为 false；原生只有 JS 模块源，同样无弹幕入口（不摆假开关） |
| 投屏 | 仍缺（能力来源不同） | Flutter 投屏按内置源能力出现，JS 模块桥没有投屏能力声明；原生未提供（系统控制中心的 AirPlay 仍可用） |

### 播放设置面板（Flutter playback_sheets.dart 逐项）

| 条目 | 状态 | 说明 |
|---|---|---|
| 倍速 | 本轮补齐 | [0.5, 0.75, 1.0, 1.1, 1.25, 1.5, 2.0, 3.0]，选中写回偏好 |
| 清晰度 | 本轮补齐 | 计划变体逐项列出，切换即以变体地址在当前进度重开；计划现在保留全部变体（旧版解析时丢弃） |
| 画面比例 | 本轮补齐 | 自动/拉伸/裁切/等宽/等高/原始/4:3/16:9 八项，按 Flutter VideoFit 尺寸规则算 AVPlayerLayer 帧 |
| 画面调节 | 本轮补齐 | 亮度/对比度/饱和度 -100..100：AVPlayerItem 视频合成 + CIColorControls 实时生效（非假滑杆）；全 0 时撤合成 |
| A-B 循环 | 本轮补齐 | 设 A 点 / 设 B 点（B 需先有 A）/ 清除，引擎周期检查到 B 即跳回 A |
| 截图 | 本轮补齐 | AVAssetImageGenerator 抓当前帧存应用文件 screenshots/，结果 toast「已保存：路径」/「截图失败」（与 Flutter 一致） |
| 音轨 | 本轮补齐 | 多音轨时列出可听选择组并可切换 |
| 字幕选择 | 本轮补齐 | 有字幕轨时列出（关闭 + 各轨）并可切换 |
| 字幕延迟 | 仍缺（平台无 API） | AVFoundation/AVPlayer 没有字幕延迟接口（mpv 有 setProperty("sub-delay")，AVPlayer 无对应物，HLS 内嵌字幕无法逐轨偏移）；面板中以一行文字明示不可用，不摆假滑杆 |
| 定时停止 | 本轮补齐 | 关闭/播完本集/15/30/60/90 分钟；节目标题随状态变「定时停止 · HH:mm 暂停」「定时停止 · 本集播完后暂停」（与 Flutter 一致） |
| 小窗播放 | 本轮补齐 | 面板行 + 顶栏/工具栏钮，均走系统 PiP |
| 锁定屏幕 | 本轮补齐 | 面板行，与工具层锁钮同一状态 |

### 黑屏根因与播放恢复

| 条目 | 状态 | 说明 |
|---|---|---|
| HLS 分片不继承 headers | 本轮补齐（主因） | 旧版 AVURLAsset 的 HTTP 头只作用于首个请求，变体列表/分片无 Cookie/UA/Referer，鉴权 CDN 直接 403 → 黑屏无限「加载中」。现实现 AVAssetResourceLoaderDelegate 资源代理（自定义 scheme）：全部子请求带头重发，播放列表响应做地址改写保证每个分片都回到代理 |
| 只有播放列表文本的计划 | 本轮补齐 | 资源代理首请求直接回文本（相对地址按 Go NativeURL 规则解析后改写），详情页「原生版暂不支持这类播放」的限制已删除 |
| 失败无错误态 | 本轮补齐 | item 失败/超时都进失败状态并透出原文（见播放页表） |
| 卡顿/403 恢复 | 本轮补齐 | 对齐 Flutter PlaybackRecovery：预算 6 次尝试 / 3 次取址，退避 0.8/1.5/2.5/4/6s；先重新取地址、再切备用线路（换画质变体）、最后按症状报错（画面长时间没有进度/视频提前结束/视频打开失败/切集后没有开始播放 + 在线/本地后缀文案，与 Flutter 一致）；位置 20 秒冻结看门狗、提前结束识别（计划时长对比）已补；原有三路即时自愈（外部暂停恢复、卡顿通知重播、音频中断续播）保留 |
| 切集看门狗 | 本轮补齐（等效） | Flutter 是切集 8 秒无开始即恢复；原生以 30 秒加载超时 + swap_no_start 归因实现，阈值不同但路径等价（AVPlayer 首帧判定比 mpv 慢，8 秒误杀率高） |

### 首页 / 搜索 / 详情 / 历史 / 资源

| 条目 | 状态 | 说明 |
|---|---|---|
| 首页分类+列表 | 已对齐 | 站源模式 categories/catalogPage、分页、warning 透出 |
| 搜索 | 已对齐 | ModuleProvider.search、最近搜索（20 条）、分页加载 |
| 详情页 | 已对齐 | 封面回落合并、30 集分组（默认续播组）、底部胶囊（下载选集开关 + 继续播放/重播/播放·第 N 集）、下载模式点集入队；修复轮 3：push 时隐藏底部 tab bar（全屏呈现，消除胶囊与 tab bar 双层叠加）；错误卡改可折叠（默认首个失败原因，展开看全文，原文不删） |
| 详情播放 | 本轮补齐 | 播放列表文本型可播；变体保留；取址错误原文透出 |
| 历史（站源） | 已对齐 | 搜索 + 来源筛选 + 今天/昨天/更早海报网格（2:3），点条目进详情按集号续播 |
| 历史（文件） | 已对齐 | 分段切换，按定位符重新取址续播；本轮给文件会话补了恢复取址（地址过期可自愈） |
| 资源（模块管理） | 已对齐 | URL 装包、启用/停用/设当前/卸载、示例模块；不内置任何站源模块 |
| 文件源管理与浏览 | 已对齐 | WebDAV/HTTP/FTP/天翼/移动，增删改、浏览、下载、播放 |

### 模块运行时（与 Go 核心对齐）

| 条目 | 状态 | 说明 |
|---|---|---|
| 实例模型 | 本轮补齐 | Go 最多 4 实例并行：已实现 ModuleRuntimePool（上限 4、惰性建、空闲复用、满员排队）；cache/票据/日志/exclusive 锁改为 provider 级共享，与 Go jsProvider 结构一致；首页+详情可真并发 |
| 调用超时中断 | 仍缺（平台无 API） | Go 有 moduleCallTimeout 60s + goja Interrupt；JSContext 无公开的脚本中断 API，模块死循环时原生无法强杀该次调用 |
| host.fetch blocked 判定 | 本轮补齐 | 按 Go catalogResponseBlockReason 实现（Cloudflare 拦截页/Cf-Mitigated challenge/_cf_chl_opt/Just a moment），错误文案走 catalogResponseError 格式；anyStatus/acceptStatus 的可接受判定同步对齐 |
| host.fetch 传输韧性 | 修复轮 3 补齐 | 传输变体阶梯（标准 → 临时会话新连接 → 临时会话 + TLS 最高 1.2），只对握手/连接级失败换变体重试、成功变体按主机记住；失败文案带 NSURLError 错误码。背景与证据链见上「修复轮 3」章节：端点网关黑洞无 ALPN 的 ClientHello、真机 -1200 为间歇性（边缘节点容忍度不一致），Go 靠 ALPN 恒开 + 整链重试绕开 |
| host.fetchText 多候选 | 本轮补齐 | 按 Go fetchProviderRequest：候选去重、多候选单试 5 秒、单候选 2 次重试（退避=尝试序号秒数、超时 12 秒）、拦截/4xx（408 除外）弃候选、全败文案「已尝试 N 个域名」 |
| host.fetchPlaylist | 本轮补齐 | 校验对齐 Go fetchMediaPlaylist：恰好 200、拦截判定、4MB 上限、#EXTM3U 校验（PlaylistError 文案） |
| prepareWebMedia/finishMedia | 本轮补齐 | 拉列表失败的错误原文透出（原先吞成「拉取播放列表失败」）；说明：Go 的 fetchMediaPlaylist 本身单地址直拉、无域名轮换，轮换只在文本抓取路径，已在 fetchText 对齐 |
| parseHtml | 本轮收窄 | 本轮补：重复属性后胜（对齐 moduleHTMLTree 的 map 覆盖）、表格隐含 tbody/tr 包装、自动闭合改作用域向上查找（li/dt/dd/td/th/tr/tbody/option/optgroup/a/button/标题/p）；仍缺（解析器实现差异）：foster parenting（表格内外文本搬移）、完整 HTML5 实体表（现为常用子集 + 数字引用）、svg/math 外部内容、adoption agency（a/formatting 元素的复杂重组）——纯 JS 子集解析器与 x/net/html 的完整 HTML5 树构建算法在这几处无法等价，畸形页面树形可能有出入 |
| reserve 限流体系 | 已对齐（语义等价） | Go 是限流票据 + 主机退避表；原生只发号 + fetch 一次性消费，对模块可观察语义等价，限流/退避本身未移植（模块感知不到差异） |
| preferredSite/catalogContext/isKnown | 已对齐 | 返回值与新装 Go 一致（空 / {more:false, background:false} / false） |
| gzip/gunzip、aesGcm、ecdh、hkdf | 已对齐 | 修复轮 1 已补齐（gzip 输出 stored 块、合法不压缩；gunzip 完整 inflate，上限 20MB） |

### 下载

| 条目 | 状态 | 说明 |
|---|---|---|
| 状态机 | 本轮补齐 | queued 等待下载 / downloading 正在下载 / converting 正在处理 / paused 已暂停 / failed 下载失败 / completed 已下载，文案逐项对齐 Flutter models.dart；Flutter 的 removing 是取消中的瞬态，原生删除为本地同步操作，无此态 |
| 暂停/继续 | 本轮补齐 | 单个 + 全部暂停/全部继续；HLS 继续时跳过已落盘分片（分片改原子写，半截不算完成）；普通文件暂停后重下；FTP 暂停在当前文件传完后生效 |
| HLS 存储形态 | 本轮补齐 | 对齐 Flutter/Go 单文件：下载完进入 converting，用 AVAssetExportSession 直通导出 media.mp4 后删分片；个别编码直通导出失败时保留分片形式，原因写进任务 note 在下载页透出 |
| 「合并」页签 | 已对齐（功能吸收） | Flutter 该页签是手动合并入口；原生改为下载完成自动合并，功能已吸收，不单设页签 |
| 本地播放失败回退 | 本轮补齐 | 本地任务播放失败可「改为在线播放」（站源重新取址/文件源重新 target），恢复取址同路 |

### 我的 / 设置

| 条目 | 状态 | 说明 |
|---|---|---|
| 「自动连播」开关 | 本轮撤除 | Flutter 设置页无此条目（只有 PlaybackPreferences.autoAdvance 字段与播放逻辑）：已撤掉我的页里的开关与入口副标题，字段、默认值（开）与连播行为保持 Flutter 原样 |
| 播放设置组 | 本轮补齐 | 在原有（默认倍速/默认静音/跳过片头片尾/保持常亮/记录历史）基础上补：双击快进快退、滑动调节亮度音量、滑动切换集数、显示时钟、显示网速、自动画中画、长按倍速、默认画面比例——键名与默认值与 PlaybackPreferences 一致 |
| 外观/弹幕/下载/存储/代理/诊断分组 | 仍缺（无对应系统） | 原生尚无这些子系统，未摆假入口；弹幕对 JS 模块源在 Flutter 版同样不可用 |

### 文件源协议细节

| 条目 | 状态 | 说明 |
|---|---|---|
| FTP PASV 0.0.0.0 | 本轮补齐 | PASV 回 0.0.0.0（或 0. 开头不可路由地址）时回退控制连接的服务器地址 |
| 移动 calSign 令牌解析 | 本轮补齐 | _account 对齐 Dart：base64 解码后以 allowMalformed 语义拆分（非 UTF-8 分段以替换字符继续），不再整串放弃 |
| 移动 success 判定 | 本轮补齐 | 对齐 Dart `success == true` 严格判定：按 CFBoolean 类型区分，JSON 数字 1 不再被误判为 true |

### 数据迁移

| 条目 | 状态 | 说明 |
|---|---|---|
| 首次启动迁移 | 已对齐 | 只读旧 Flutter 容器（模块/历史/设置/文件源与进度），合并语义、成功才写标记、幂等；真机首测部分成功（模块 2、历史 25），完整性仍待真机终验 |

## 数据存储格式

全部数据在 App 容器 `Application Support/LvguoNative/` 下：

```
LvguoNative/
  library.json                 模块库索引：{"current": "<id>", "disabled": ["<id>", …]}
  modules/<id>/manifest.json   模块清单（原文）
  modules/<id>/main.js         模块脚本（原文）
  module-state/module-<id>-<name>   host.loadState/saveState 的持久化值（原文字符串）
  file-sources.json            文件源数组（字段与 Flutter FileSource.toJson 一致）
  file-progress.json           文件播放进度
  history.json                 站源观看历史（WatchEntry 同构，cap 300）
  settings.json                播放设置（PlaybackPreferences 同键名）
  recent-searches.json         搜索历史词（最多 20）
  downloads.json + downloads/<id>/   下载任务与文件（HLS 合并后为 media.mp4 单文件）
  screenshots/                 播放截图
```

模块内存缓存（cacheGet/cacheSet）不落盘，与 Go 版一致。

### 首次启动数据迁移（`Data/Migration.swift`）

覆盖安装保留容器是前提——同包名、同签名，工程里不要加任何改变容器
身份的设置。迁移在任何 Store 读盘之前执行：只读旧数据、只写原生
目录，合并语义（已有不覆盖、历史按时间取新），全部成功后写
`migration-v1.json` 标记保证幂等；任一子项失败不写标记、下次启动
重试，且不改动旧数据。来源与依据见代码注释（旧 Go 核心数据目录、
store/users/<active>/、SharedPreferences 的 flutter.* 键）。

## CI

`.github/workflows/build-ios.yml`（仅 native-rewrite 分支）：macOS 构建机
选最新 Xcode，运行 `ios-native/ci-build.sh` 无签名构建，产物为未签名 IPA
（artifact 下载）。
