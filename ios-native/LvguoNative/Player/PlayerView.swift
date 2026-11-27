import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - 画中画桥

/// AVPictureInPictureController 的状态桥：控制器挂在
/// AVPlayerLayer 上（不再用 AVPlayerViewController 的自带
/// 控件——双控件层叠加正是旧版左上角控键重叠的原因）。
final class PiPBridge: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    var controller: AVPictureInPictureController?
    @Published var isPossible = false
    @Published var isActive = false
    var onStopped: (() -> Void)?
    private var possibleObservation: NSKeyValueObservation?

    func attach(to layer: AVPlayerLayer) {
        if controller?.playerLayer === layer { return }
        guard let created = AVPictureInPictureController(playerLayer: layer) else {
            return
        }
        created.delegate = self
        controller = created
        possibleObservation = created.observe(
            \AVPictureInPictureController.isPictureInPicturePossible, options: [.new]
        ) { [weak self] controller, _ in
            DispatchQueue.main.async {
                self?.isPossible = controller.isPictureInPicturePossible
            }
        }
        isPossible = created.isPictureInPicturePossible
    }

    func start() { controller?.startPictureInPicture() }
    func stop() { controller?.stopPictureInPicture() }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        isActive = false
        onStopped?()
    }
}

/// 画中画进行中退出播放页时，引擎由它托管续命（对齐 Flutter
/// 版 PiP 激活后页面 pop、PlaybackHost 接管会话的行为）；
/// 画中画关闭后自动暂停并释放。
final class PlaybackKeepAlive {
    static let shared = PlaybackKeepAlive()
    private var engine: PlaybackEngine?

    func adopt(_ engine: PlaybackEngine, bridge: PiPBridge) {
        self.engine = engine
        bridge.onStopped = { [weak self, weak engine] in
            engine?.pause()
            self?.engine = nil
        }
    }
}

// MARK: - 播放层（AVPlayerLayer + 画面比例布局）

/// 承载 AVPlayerLayer 的视图：画面比例按 Flutter VideoFit 的
/// 尺寸规则算 layer 帧（auto/crop 用 min/max fit、fitWidth/
/// fitHeight 单边定尺、original 按像素/像素比、4:3/16:9 先
/// 换目标比例再 fit），gravity 恒为 resize（帧已是目标比例）。
final class PlayerContainerView: UIView {
    let playerLayer = AVPlayerLayer()
    var fit: VideoFitMode = .auto {
        didSet { setNeedsLayout() }
    }
    var videoSize: CGSize = .zero {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resize
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = Self.frame(
            fit: fit, videoSize: videoSize, box: bounds
        )
    }

    static func frame(fit: VideoFitMode, videoSize: CGSize, box: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, box.width > 0, box.height > 0 else {
            return box
        }
        let aspect = Double(videoSize.width / videoSize.height)
        func fitted(_ targetAspect: Double, fill: Bool) -> CGSize {
            let height = fill
                ? max(box.height, box.width / targetAspect)
                : min(box.height, box.width / targetAspect)
            return CGSize(width: height * targetAspect, height: height)
        }
        let size: CGSize
        switch fit {
        case .auto:
            size = fitted(aspect, fill: false)
        case .crop:
            size = fitted(aspect, fill: true)
        case .stretch:
            size = box.size
        case .fitWidth:
            size = CGSize(width: box.width, height: box.width / aspect)
        case .fitHeight:
            size = CGSize(width: box.height * aspect, height: box.height)
        case .original:
            let scale = Double(UIScreen.main.scale)
            size = CGSize(width: Double(videoSize.width) / scale,
                          height: Double(videoSize.height) / scale)
        case .ratio4x3:
            size = fitted(aspect < 1 ? 3.0 / 4.0 : 4.0 / 3.0, fill: false)
        case .ratio16x9:
            size = fitted(aspect < 1 ? 9.0 / 16.0 : 16.0 / 9.0, fill: false)
        }
        return CGRect(
            x: box.midX - size.width / 2,
            y: box.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fit: VideoFitMode
    let videoSize: CGSize
    let pipBridge: PiPBridge

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.fit = fit
        view.videoSize = videoSize
        pipBridge.attach(to: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
            pipBridge.attach(to: view.playerLayer)
        }
        view.fit = fit
        view.videoSize = videoSize
    }
}

/// 隐藏的系统音量视图：滑动调音量时靠它的 UISlider 改系统音量
struct SystemVolumeView: UIViewRepresentable {
    static weak var shared: MPVolumeView?

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        view.alpha = 0.02
        Self.shared = view
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    static func setVolume(_ value: Float) {
        guard let view = shared else { return }
        for subview in view.subviews {
            if let slider = subview as? UISlider {
                slider.value = value
                return
            }
        }
    }

    static var currentVolume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }
}

// MARK: - 播放会话

/// 播放会话：由调用方（详情页 / 文件浏览页 / 历史页 / 下载页）
/// 持有，把「当前播的是哪一集/哪个文件」的知识留在调用方，
/// 播放页只在进度、播完、上下集、选集、恢复时喊它。
final class PlaybackSession {
    var index: Int = 0
    var canNext: Bool = false
    var canPrevious: Bool = false
    /// 顶部栏标题（剧名/文件名，不带集号）
    var displayTitle: String = ""
    /// 选集面板的条目标签（与 index 同序）
    var episodeLabels: [String] = []
    var onProgress: ((PlaybackSession, Double, Double) -> Void)?
    var onNext: ((PlaybackSession) async -> PlaybackRequest?)?
    var onPrevious: ((PlaybackSession) async -> PlaybackRequest?)?
    var onSelectEpisode: ((PlaybackSession, Int) async -> PlaybackRequest?)?
    /// 恢复时重新取址（重走 resolveMedia / 重新 target）
    var onRefresh: ((PlaybackSession) async -> PlaybackRequest?)?
    /// 本地播放失败时的「改为在线播放」
    var onlineFallback: ((PlaybackSession) async -> PlaybackRequest?)?
    /// handler 取址失败时的原始错误（播放页以 toast 透出）
    var lastError: String?
}

// MARK: - 播放页

/// 播放页：单一控件层（AVPlayerLayer + 自绘控件），布局与行为
/// 以 Flutter 版 PlayerSurface 为唯一规格：顶部栏（返回/标题/
/// 画中画/设置）、手势区（点按显隐、双击快进快退、长按倍速、
/// 横滑进度、竖滑亮度/音量或切集）、底部渐变上的进度条与
/// 工具栏（上下集/播放/时间/清晰度/倍速/画面比例/选集/
/// 定时/画中画）、锁定、暂停标记、加载与失败状态。
/// 控件外观用系统玻璃与系统菜单/sheet（用户 2026-11-27 定：
/// 功能与行为对齐优先，外观用系统控件即可）。
struct PlayerPage: View {
    let request: PlaybackRequest
    var session: PlaybackSession? = nil

    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var engine = PlaybackEngine()
    @StateObject private var pipBridge = PiPBridge()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var currentRequest: PlaybackRequest?
    @State private var switching = false
    @State private var controlsVisible = true
    @State private var locked = false
    @State private var lockPeek = false
    @State private var hint: String?
    @State private var toast: String?
    @State private var showSettings = false
    @State private var showEpisodes = false

    // 手势状态
    @State private var dragSeekTarget: Double?
    @State private var streakSeconds: Double = 0
    @State private var streakDirection: Double = 0
    @State private var levelBadge: (icon: String, fraction: Double)?
    @State private var episodeHint: String?
    @State private var boostActive = false
    @State private var scrubValue: Double?

    // 播放设置面板状态（会话级，对齐 Flutter 播放设置 sheet）
    @State private var fitOverride: VideoFitMode?
    @State private var eqBrightness = 0
    @State private var eqContrast = 0
    @State private var eqSaturation = 0
    @State private var sleepOption: SleepOption = .off
    @State private var sleepDeadline: Date?

    private enum SleepOption: Equatable {
        case off
        case episodeEnd
        case minutes(Int)
    }

    private enum DragKind {
        case none
        case seek
        case level(brightness: Bool, start: Double)
        case episode
    }
    @State private var dragKind: DragKind = .none
    @State private var dragStartPosition: Double = 0

    private var activeRequest: PlaybackRequest { currentRequest ?? request }
    private var fit: VideoFitMode {
        fitOverride ?? VideoFitMode(rawValue: settings.videoFit) ?? .auto
    }
    private var displayTitle: String {
        if let session, !session.displayTitle.isEmpty { return session.displayTitle }
        return activeRequest.title
    }
    private var displayPosition: Double {
        scrubValue ?? dragSeekTarget ?? engine.currentTime
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(
                player: engine.player,
                fit: fit,
                videoSize: engine.presentationSize,
                pipBridge: pipBridge
            )
            .ignoresSafeArea()

            gestureSurface

            centerOverlays

            if controlsVisible, !locked, engine.phase != .failed {
                chrome
            }
            if locked, lockPeek {
                lockButton(peekOnly: true)
            }
            if engine.isPaused, engine.phase == .ready, !locked {
                pausedMark
            }
            badges

            SystemVolumeView()
                .frame(width: 1, height: 1)
                .opacity(0.02)
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showSettings) {
            PlaybackSettingsSheet(
                engine: engine,
                variants: activeRequest.variants,
                currentQuality: activeRequest.quality,
                currentSpeed: settings.speed,
                fit: fit,
                eqBrightness: $eqBrightness,
                eqContrast: $eqContrast,
                eqSaturation: $eqSaturation,
                sleepLabel: sleepSectionLabel,
                sleepSelection: sleepSelection,
                pipPossible: pipBridge.isPossible,
                onSpeed: { speed in
                    engine.playbackRate = Float(speed)
                    settings.speed = speed
                    if !engine.isPaused { engine.play() }
                },
                onQuality: { variant in switchQuality(variant) },
                onFit: { fitOverride = $0 },
                onScreenshot: { await takeScreenshot() },
                onSleep: { raw in applySleepSelection(raw) },
                onPiP: { pipBridge.start() },
                onLock: {
                    showSettings = false
                    setLocked(true)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showEpisodes) {
            EpisodeGridSheet(
                labels: session?.episodeLabels ?? [],
                current: session?.index ?? 0
            ) { index in
                showEpisodes = false
                Task { await selectEpisode(index) }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear(perform: start)
        .onDisappear {
            if settings.keepScreenAwake {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            if pipBridge.isActive {
                PlaybackKeepAlive.shared.adopt(engine, bridge: pipBridge)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background,
               settings.autoPictureInPicture,
               !engine.isPaused, pipBridge.isPossible {
                pipBridge.start()
            }
        }
        .onChange(of: engine.isPlaying) { _, _ in scheduleControlsHide() }
    }

    // MARK: 生命周期

    private func start() {
        PlaybackEngine.configureAudioSession()
        engine.playbackRate = Float(settings.speed)
        engine.outroThreshold = settings.autoAdvance
            ? Double(settings.skipOutroSeconds) : 0
        if settings.startMuted {
            engine.player.isMuted = true
        }
        if settings.keepScreenAwake {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        wireEngine()
        engine.load(effectiveRequest(request), autoplay: true)
        scheduleControlsHide()
    }

    /// 跳过片头：起始位置不足片头秒数时抬到片头结束处
    private func effectiveRequest(_ base: PlaybackRequest) -> PlaybackRequest {
        var result = base
        let intro = Double(settings.skipIntroSeconds)
        if intro > 0, result.startPosition < intro {
            result.startPosition = intro
        }
        return result
    }

    private func wireEngine() {
        if let session {
            engine.onProgress = { position, duration in
                session.onProgress?(session, position, duration)
            }
        }
        engine.onEnded = {
            if sleepOption == .episodeEnd {
                engine.pause()
                return
            }
            guard settings.autoAdvance else { return }
            Task { await switchEpisode(previous: false) }
        }
        engine.onOutroReached = {
            if sleepOption == .episodeEnd {
                engine.pause()
                return
            }
            guard settings.autoAdvance else { return }
            Task { await switchEpisode(previous: false) }
        }
        engine.onRecover = { [self] reason, attempt in
            await recoverRequest(reason: reason, attempt: attempt)
        }
    }

    /// 恢复取址（对齐 Flutter 恢复顺序）：前 3 次重新取地址，
    /// 之后切备用线路（换一个画质变体的地址），再不行继续取址
    private func recoverRequest(reason: String, attempt: Int) async -> PlaybackRequest? {
        guard let session else { return nil }
        if attempt > 3 {
            let current = activeRequest
            if let alternative = current.variants.first(where: {
                $0.quality != current.quality && $0.isPlayable
            }) {
                let switched = current.withVariant(alternative)
                currentRequest = switched
                return switched
            }
        }
        let fresh = await session.onRefresh?(session)
        if let fresh {
            currentRequest = fresh
        }
        return fresh
    }

    private func saveProgressNow() {
        guard engine.duration > 0 || engine.currentTime > 0,
              let session else { return }
        session.onProgress?(session, engine.currentTime, engine.duration)
    }

    // MARK: 切集 / 选集 / 清晰度

    private func switchEpisode(previous: Bool) async {
        guard let session, !switching else { return }
        switching = true
        defer { switching = false }
        saveProgressNow()
        session.lastError = nil
        let next = previous
            ? await session.onPrevious?(session)
            : await session.onNext?(session)
        await applySwitched(next, fallbackMessage: previous ? "上一集加载失败" : "下一集加载失败")
    }

    private func selectEpisode(_ index: Int) async {
        guard let session, !switching, index != session.index else { return }
        switching = true
        defer { switching = false }
        saveProgressNow()
        session.lastError = nil
        let target = await session.onSelectEpisode?(session, index)
        await applySwitched(target, fallbackMessage: "这一集加载失败")
    }

    private func applySwitched(_ next: PlaybackRequest?, fallbackMessage: String) async {
        guard let next else {
            if let error = session?.lastError {
                showToast(error)
            } else {
                showToast(fallbackMessage)
            }
            return
        }
        currentRequest = next
        engine.load(effectiveRequest(next), autoplay: true, isSwitch: true)
        showControls()
    }

    private func switchQuality(_ variant: PlaybackVariant) {
        let current = activeRequest
        guard variant.quality != current.quality else { return }
        var switched = current.withVariant(variant)
        switched.startPosition = engine.currentTime
        currentRequest = switched
        engine.load(switched, autoplay: true)
        showToast("已切换到 \(variant.label)")
    }

    // MARK: 控件显隐 / 提示

    @State private var hideWork: DispatchWorkItem?
    @State private var hintWork: DispatchWorkItem?
    @State private var toastWork: DispatchWorkItem?
    @State private var tapWork: DispatchWorkItem?

    private func showControls() {
        controlsVisible = true
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            if !engine.isPaused, engine.phase == .ready {
                controlsVisible = false
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func showHint(_ text: String) {
        hint = text
        hintWork?.cancel()
        let work = DispatchWorkItem { hint = nil }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func setLocked(_ value: Bool) {
        locked = value
        lockPeek = false
        if value {
            controlsVisible = false
            showHint("已锁定，点屏幕显示锁图标")
        } else {
            showHint("已解锁")
            showControls()
        }
    }

    // MARK: 手势层

    private var gestureSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in handleDoubleTap(at: value.location) }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1)
                    .onEnded { _ in handleSingleTap() }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in handleDragChanged(value) }
                    .onEnded { value in handleDragEnded(value) }
            )
            .onLongPressGesture(
                minimumDuration: 0.3, maximumDistance: 12,
                pressing: { pressing in
                    if !locked, engine.phase == .ready, !engine.isPaused {
                        boostActive = pressing
                        engine.player.rate = pressing
                            ? Float(settings.boostSpeed)
                            : engine.playbackRate
                        if pressing { showControls() }
                    }
                },
                perform: {}
            )
    }

    private func handleSingleTap() {
        tapWork?.cancel()
        let work = DispatchWorkItem {
            if locked {
                lockPeek.toggle()
                if lockPeek { showHint("已锁定，点击锁图标解锁") }
                return
            }
            if controlsVisible {
                controlsVisible = false
            } else {
                showControls()
            }
        }
        tapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func handleDoubleTap(at location: CGPoint) {
        tapWork?.cancel()
        guard !locked else { return }
        let width = UIScreen.main.bounds.width
        if settings.doubleTapSeek, location.x < width / 4 || location.x > width * 3 / 4 {
            let direction: Double = location.x < width / 4 ? -1 : 1
            if streakDirection != direction {
                streakSeconds = 0
                streakDirection = direction
            }
            streakSeconds += 10
            scheduleStreakCommit()
        } else {
            engine.togglePlayPause()
            showControls()
        }
    }

    @State private var streakWork: DispatchWorkItem?

    private func scheduleStreakCommit() {
        streakWork?.cancel()
        let work = DispatchWorkItem {
            let delta = streakDirection * streakSeconds
            if delta != 0 {
                engine.seek(to: engine.currentTime + delta)
            }
            streakSeconds = 0
            streakDirection = 0
        }
        streakWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        guard !locked else { return }
        let size = UIScreen.main.bounds.size
        if dragKind == .none {
            let horizontal = abs(value.translation.width) > abs(value.translation.height)
            if horizontal {
                dragKind = .seek
                dragStartPosition = engine.currentTime
            } else if settings.swipeLevels {
                let brightness = value.startLocation.x < size.width / 2
                dragKind = .level(
                    brightness: brightness,
                    start: brightness
                        ? Double(UIScreen.main.brightness)
                        : Double(SystemVolumeView.currentVolume)
                )
            } else if settings.swipeEpisodes {
                dragKind = .episode
            } else {
                return
            }
        }
        switch dragKind {
        case .seek:
            let span = min(engine.duration, 120)
            guard engine.duration > 0, span > 0 else { return }
            let delta = Double(value.translation.width / size.width) * span
            dragSeekTarget = min(max(0, dragStartPosition + delta), engine.duration)
        case .level(let brightness, let start):
            let fraction = min(max(0, start - Double(value.translation.height / size.height)), 1)
            if brightness {
                UIScreen.main.brightness = CGFloat(fraction)
                levelBadge = ("sun.max.fill", fraction)
            } else {
                SystemVolumeView.setVolume(Float(fraction))
                levelBadge = (fraction == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", fraction)
            }
        case .episode:
            guard let session else { return }
            if value.translation.height < -60 {
                episodeHint = session.canNext ? "松手播放下一集" : "已经是最后一集"
            } else if value.translation.height > 60 {
                episodeHint = session.canPrevious ? "松手播放上一集" : "已经是第一集"
            } else {
                episodeHint = nil
            }
        case .none:
            break
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        defer {
            dragKind = .none
            dragSeekTarget = nil
            levelBadge = nil
            episodeHint = nil
        }
        guard !locked else { return }
        switch dragKind {
        case .seek:
            if let target = dragSeekTarget {
                engine.seek(to: target)
            }
        case .episode:
            if value.translation.height < -60 {
                Task { await switchEpisode(previous: false) }
            } else if value.translation.height > 60 {
                Task { await switchEpisode(previous: true) }
            }
        default:
            break
        }
        showControls()
    }

    // MARK: 中央状态层

    @ViewBuilder
    private var centerOverlays: some View {
        if engine.phase == .loading {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(engine.loadingMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
            }
        } else if engine.phase == .failed {
            failureOverlay
        } else if engine.isStalled, !engine.isPaused {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    private var failureOverlay: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "play.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.8))
                Text("暂时无法播放")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(engine.failureText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Button(activeRequest.isLocal ? "重试本地播放" : "重试") {
                        engine.retryFromUI(fromStart: false)
                    }
                    .buttonStyle(.glassProminent)
                    if engine.currentTime > 0 {
                        Button("从头播放") {
                            engine.retryFromUI(fromStart: true)
                        }
                        .buttonStyle(.glass)
                    }
                    if activeRequest.isLocal, let session,
                       let fallback = session.onlineFallback {
                        Button("改为在线播放") {
                            Task {
                                if let online = await fallback(session) {
                                    currentRequest = online
                                    engine.load(online, autoplay: true)
                                }
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }
                Button("返回") {
                    saveProgressNow()
                    engine.pause()
                    dismiss()
                }
                .buttonStyle(.glass)
            }
            .padding(24)
        }
    }

    private var pausedMark: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    engine.play()
                    showControls()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.bottom, 92)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var badges: some View {
        VStack {
            if boostActive {
                badgeCapsule("倍速播放中")
                    .padding(.top, 64)
            } else if let hint {
                badgeCapsule(hint)
                    .padding(.top, 64)
            }
            Spacer()
            if streakSeconds > 0 {
                badgeCapsule(streakDirection > 0
                    ? "快进 \(Int(streakSeconds)) 秒"
                    : "快退 \(Int(streakSeconds)) 秒")
            } else if let target = dragSeekTarget {
                badgeCapsule("\(clockText(target)) / \(clockText(engine.duration))")
            } else if let levelBadge {
                HStack(spacing: 10) {
                    Image(systemName: levelBadge.icon)
                    ProgressView(value: levelBadge.fraction)
                        .frame(width: 120)
                        .tint(.white)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
            } else if let episodeHint {
                badgeCapsule(episodeHint)
            }
            Spacer()
            if let toast {
                badgeCapsule(toast)
                    .padding(.bottom, 120)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func badgeCapsule(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
    }

    // MARK: 顶部栏与底部控件

    private var chrome: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomControls
            }
            lockButton(peekOnly: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 10)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                saveProgressNow()
                engine.pause()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .padding(10)
            }
            .buttonStyle(.glass)
            Text(displayTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4)
            Spacer()
            if settings.showNetworkSpeed, !engine.networkSpeedText.isEmpty {
                Text(engine.networkSpeedText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            if settings.showClock {
                TimelineView(.periodic(from: Date(), by: 20)) { context in
                    Text(Self.wallClock(context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            if pipBridge.isPossible {
                Button {
                    pipBridge.start()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.headline)
                        .padding(10)
                }
                .buttonStyle(.glass)
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.headline)
                    .padding(10)
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private static func wallClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private var bottomControls: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.78)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 200)
            .allowsHitTesting(false)
            VStack(spacing: 2) {
                sliderRow
                toolbar
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var sliderRow: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geometry in
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 4)
                    .position(x: geometry.size.width / 2, y: 14)
                if engine.duration > 0 {
                    Capsule()
                        .fill(.white.opacity(0.45))
                        .frame(
                            width: geometry.size.width
                                * min(1, engine.bufferedPosition / engine.duration),
                            height: 4
                        )
                        .position(
                            x: geometry.size.width
                                * min(1, engine.bufferedPosition / engine.duration) / 2,
                            y: 14
                        )
                }
            }
            .frame(height: 28)
            Slider(
                value: Binding(
                    get: { displayPosition },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(engine.duration, 1)
            ) { editing in
                if !editing, let value = scrubValue {
                    engine.seek(to: value)
                    scrubValue = nil
                }
                showControls()
            }
            .tint(.green)
            .frame(height: 28)
        }
        .frame(height: 28)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if let session {
                Button {
                    Task { await switchEpisode(previous: true) }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .frame(width: 40, height: 48)
                }
                .disabled(!session.canPrevious || switching)
            }
            Button {
                engine.togglePlayPause()
                showControls()
            } label: {
                Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 30))
                    .frame(width: 48, height: 48)
            }
            if let session {
                Button {
                    Task { await switchEpisode(previous: false) }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 40, height: 48)
                }
                .disabled(!session.canNext || switching)
            }
            Text("\(clockText(displayPosition)) / \(clockText(engine.duration))")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.white.opacity(0.86))
                .padding(.leading, 8)
            Spacer()
            if activeRequest.variants.count > 1 {
                Menu {
                    ForEach(activeRequest.variants.sorted(by: { $0.quality > $1.quality }), id: \.quality) { variant in
                        Button {
                            switchQuality(variant)
                        } label: {
                            if variant.quality == activeRequest.quality {
                                Label(variant.label, systemImage: "checkmark")
                            } else {
                                Text(variant.label)
                            }
                        }
                    }
                } label: {
                    Text(qualityLabel)
                        .font(.subheadline.weight(.medium))
                        .frame(height: 48)
                        .padding(.horizontal, 6)
                }
            }
            Menu {
                ForEach(Self.speedOptions, id: \.self) { speed in
                    Button {
                        engine.playbackRate = Float(speed)
                        settings.speed = speed
                        if !engine.isPaused { engine.play() }
                    } label: {
                        if speed == settings.speed {
                            Label(speedLabel(speed), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(speed))
                        }
                    }
                }
            } label: {
                Text(speedLabel(settings.speed))
                    .font(.subheadline.weight(.bold))
                    .frame(height: 48)
                    .padding(.horizontal, 6)
            }
            Menu {
                ForEach(VideoFitMode.allCases, id: \.self) { mode in
                    Button {
                        fitOverride = mode
                    } label: {
                        if mode == fit {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "aspectratio")
                    .frame(width: 40, height: 48)
            }
            if session?.onSelectEpisode != nil {
                Button {
                    showEpisodes = true
                } label: {
                    Image(systemName: "list.number")
                        .frame(width: 40, height: 48)
                }
            }
            Menu {
                Button("关闭") { applySleep(.off) }
                Button("播完本集") { applySleep(.episodeEnd) }
                ForEach([15, 30, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) 分钟") { applySleep(.minutes(minutes)) }
                }
            } label: {
                Image(systemName: sleepOption == .off ? "moon" : "moon.zzz.fill")
                    .frame(width: 40, height: 48)
            }
            if pipBridge.isPossible {
                Button {
                    pipBridge.start()
                } label: {
                    Image(systemName: "pip.enter")
                        .frame(width: 40, height: 48)
                }
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private var qualityLabel: String {
        if activeRequest.quality > 0 {
            return "\(activeRequest.quality)P"
        }
        return activeRequest.variants.map(\.quality).max().map { "\($0)P" } ?? "自动"
    }

    private func lockButton(peekOnly: Bool) -> some View {
        Button {
            setLocked(!locked)
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.headline)
                .padding(10)
        }
        .buttonStyle(.glass)
    }

    // MARK: 定时停止 / 截图

    static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.1, 1.25, 1.5, 2.0, 3.0]

    private var sleepSectionLabel: String {
        switch sleepOption {
        case .off:
            return "定时停止"
        case .episodeEnd:
            return "定时停止 · 本集播完后暂停"
        case .minutes:
            if let deadline = sleepDeadline {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                return "定时停止 · \(formatter.string(from: deadline)) 暂停"
            }
            return "定时停止"
        }
    }

    @State private var sleepTask: Task<Void, Never>?

    /// 定时停止的当前选择（给设置面板打勾用）：off / episode / minutes:N
    private var sleepSelection: String {
        switch sleepOption {
        case .off: return "off"
        case .episodeEnd: return "episode"
        case .minutes(let minutes): return "minutes:\(minutes)"
        }
    }

    private func applySleepSelection(_ raw: String) {
        switch raw {
        case "off":
            applySleep(.off)
        case "episode":
            applySleep(.episodeEnd)
        default:
            if raw.hasPrefix("minutes:"),
               let minutes = Int(raw.dropFirst("minutes:".count)) {
                applySleep(.minutes(minutes))
            }
        }
    }

    private func applySleep(_ option: SleepOption) {
        sleepOption = option
        sleepTask?.cancel()
        sleepDeadline = nil
        if case .minutes(let minutes) = option {
            sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60)
            sleepTask = Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(minutes) * 60 * 1_000_000_000
                )
                if !Task.isCancelled {
                    engine.pause()
                    sleepOption = .off
                    sleepDeadline = nil
                    showToast("定时停止，已暂停播放")
                }
            }
        }
    }

    private func takeScreenshot() async {
        showSettings = false
        do {
            let path = try await engine.captureScreenshot()
            showToast("已保存：\(path)")
        } catch {
            showToast("截图失败")
        }
    }
}

// MARK: - 播放设置面板

/// 播放设置：条目与顺序对齐 Flutter playback_sheets.dart
/// （倍速/清晰度/画面比例/画面调节/A-B 循环/截图/字幕/音轨/
/// 定时停止/小窗/锁定）。控件用系统 List 与开关/滑杆。
/// 字幕延迟不摆假滑杆：AVPlayer 没有字幕延迟接口，面板里
/// 只给一行说明（见 README 对齐表）。
struct PlaybackSettingsSheet: View {
    @ObservedObject var engine: PlaybackEngine
    let variants: [PlaybackVariant]
    let currentQuality: Int
    let currentSpeed: Double
    let fit: VideoFitMode
    @Binding var eqBrightness: Int
    @Binding var eqContrast: Int
    @Binding var eqSaturation: Int
    let sleepLabel: String
    let sleepSelection: String
    let pipPossible: Bool
    let onSpeed: (Double) -> Void
    let onQuality: (PlaybackVariant) -> Void
    let onFit: (VideoFitMode) -> Void
    let onScreenshot: () async -> Void
    let onSleep: (String) -> Void
    let onPiP: () -> Void
    let onLock: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("倍速") {
                    ForEach(PlayerPage.speedOptions, id: \.self) { speed in
                        checkRow(
                            title: speedLabel(speed),
                            checked: speed == currentSpeed
                        ) {
                            onSpeed(speed)
                        }
                    }
                }
                if variants.count > 1 {
                    Section("清晰度") {
                        ForEach(
                            variants.sorted(by: { $0.quality > $1.quality }),
                            id: \.quality
                        ) { variant in
                            checkRow(
                                title: variant.label,
                                checked: variant.quality == currentQuality
                            ) {
                                onQuality(variant)
                            }
                        }
                    }
                }
                Section("画面比例") {
                    ForEach(VideoFitMode.allCases, id: \.self) { mode in
                        checkRow(title: mode.label, checked: mode == fit) {
                            onFit(mode)
                        }
                    }
                }
                Section("画面调节") {
                    eqSlider("亮度", value: $eqBrightness)
                    eqSlider("对比度", value: $eqContrast)
                    eqSlider("饱和度", value: $eqSaturation)
                }
                Section("A-B 循环") {
                    HStack {
                        Button(engine.abA == nil
                            ? "设 A 点"
                            : "A \(clockText(engine.abA ?? 0))") {
                            engine.setPointA()
                        }
                        Spacer()
                        Button(engine.abB == nil
                            ? "设 B 点"
                            : "B \(clockText(engine.abB ?? 0))") {
                            engine.setPointB()
                        }
                        .disabled(engine.abA == nil)
                        if engine.abA != nil || engine.abB != nil {
                            Spacer()
                            Button("清除", role: .destructive) {
                                engine.clearAB()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section("截图") {
                    Button("截图") {
                        Task { await onScreenshot() }
                    }
                    Text("保存当前帧到应用文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !engine.subtitleOptions.isEmpty {
                    Section("字幕") {
                        ForEach(engine.subtitleOptions) { option in
                            checkRow(title: option.title, checked: option.selected) {
                                engine.selectSubtitle(id: option.id)
                            }
                        }
                        Text("字幕延迟：AVPlayer 没有字幕延迟接口，此项不可用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if engine.audioOptions.count > 1 {
                    Section("音轨") {
                        ForEach(engine.audioOptions) { option in
                            checkRow(title: option.title, checked: option.selected) {
                                engine.selectAudioTrack(id: option.id)
                            }
                        }
                    }
                }
                Section(sleepLabel) {
                    checkRow(title: "关闭", checked: sleepSelection == "off") {
                        onSleep("off")
                    }
                    checkRow(title: "播完本集", checked: sleepSelection == "episode") {
                        onSleep("episode")
                    }
                    ForEach([15, 30, 60, 90], id: \.self) { minutes in
                        checkRow(
                            title: "\(minutes) 分钟",
                            checked: sleepSelection == "minutes:\(minutes)"
                        ) {
                            onSleep("minutes:\(minutes)")
                        }
                    }
                }
                Section {
                    Button {
                        dismiss()
                        onPiP()
                    } label: {
                        Label("小窗播放", systemImage: "pip.enter")
                    }
                    .disabled(!pipPossible)
                    Button {
                        onLock()
                    } label: {
                        Label("锁定屏幕", systemImage: "lock")
                    }
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onChange(of: eqBrightness) { _, _ in applyEQ() }
        .onChange(of: eqContrast) { _, _ in applyEQ() }
        .onChange(of: eqSaturation) { _, _ in applyEQ() }
    }

    private func applyEQ() {
        engine.setVideoEQ(
            brightness: eqBrightness, contrast: eqContrast, saturation: eqSaturation
        )
    }

    private func eqSlider(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: -100...100, step: 1
            )
            Text("\(value.wrappedValue)")
                .font(.callout.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func checkRow(
        title: String, checked: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if checked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 选集面板

struct EpisodeGridSheet: View {
    let labels: [String]
    let current: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 76), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(labels.indices, id: \.self) { index in
                        Button {
                            onSelect(index)
                            dismiss()
                        } label: {
                            Text(labels[index])
                                .font(.footnote.weight(
                                    index == current ? .semibold : .regular
                                ))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            index == current
                                ? .regular.tint(.green.opacity(0.35))
                                : .regular,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
