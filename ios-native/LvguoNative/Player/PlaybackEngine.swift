import AVFoundation
import Combine
import Foundation

/// 一次播放请求：与 Flutter 版 PlaybackPlan 对齐的最小结构（url + headers）
struct PlaybackRequest {
    var url: URL
    var headers: [String: String] = [:]
    var title: String = ""
    /// 续播起始位置（秒），0 = 从头
    var startPosition: Double = 0
}

/// AVPlayer 播放引擎。针对 Flutter 版实测痛点做架构级处理：
/// 1. 卡顿（stall）后若用户意图是播放，自动恢复 play()——不再「突然暂停不续播」；
/// 2. 系统音频中断结束后，按中断前状态自动续播；
/// 3. timeControlStatus 被外部原因暂停且非用户操作时，尝试恢复。
/// 所有自动恢复都受 intentToPlay 门控，绝不和用户手动暂停打架。
final class PlaybackEngine: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var statusText = "未加载"
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    /// 进度回调（约每 5 秒一次 + 暂停/结束时）：供历史记录用
    var onProgress: ((Double, Double) -> Void)?
    /// 播放结束回调：供自动连播用
    var onEnded: (() -> Void)?
    /// 到达片尾阈值回调（skipOutroSeconds > 0 时）：提前切下一集
    var onOutroReached: (() -> Void)?
    /// 片尾提前量（秒），0 = 关闭；每次 load 重置触发标记
    var outroThreshold: Double = 0
    private var outroFired = false

    /// 播放倍速（play 时以此速率播放）
    var playbackRate: Float = 1.0
    private var pendingStartPosition: Double = 0
    private var progressTick = 0

    /// 用户意图：只有为 true 时才允许自动恢复
    private var intentToPlay = false
    private var wasPlayingBeforeInterruption = false

    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeObserver: Any?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = player.observe(\AVPlayer.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isPlaying = player.timeControlStatus == .playing
                if player.timeControlStatus == .paused,
                   self.intentToPlay,
                   player.currentItem?.status == .readyToPlay {
                    // 非用户意图的暂停（路由变化 / 系统回收等）：恢复播放
                    self.play()
                }
            }
        }
        // 每 0.5 秒发布进度；约每 5 秒回调一次 onProgress
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let position = time.seconds.isFinite ? time.seconds : 0
            self.currentTime = position
            if let itemDuration = self.player.currentItem?.duration.seconds,
               itemDuration.isFinite {
                self.duration = itemDuration
            }
            self.progressTick += 1
            if self.progressTick % 10 == 0 {
                self.onProgress?(self.currentTime, self.duration)
            }
            if self.outroThreshold > 0, !self.outroFired,
               self.duration > 0,
               self.duration - position <= self.outroThreshold,
               position > 0 {
                self.outroFired = true
                self.onOutroReached?()
            }
        }
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[Playback] audio session error: \(error)")
        }
    }

    func load(_ request: PlaybackRequest, autoplay: Bool = true) {
        intentToPlay = autoplay
        pendingStartPosition = request.startPosition
        outroFired = false
        progressTick = 0
        currentTime = 0
        duration = 0
        // AVURLAsset 的 HTTP 头注入点。
        // 注意：HLS 分片请求不继承该头，二期用 AVAssetResourceLoaderDelegate 处理带头分片。
        // 该键在 Swift 中没有桥接常量，用字面量字符串（值与 AVURLAssetHTTPHeaderFieldsKey 相同）
        let asset = AVURLAsset(url: request.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": request.headers
        ])
        let item = AVPlayerItem(asset: asset)
        itemStatusObservation = item.observe(\AVPlayerItem.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.statusText = "就绪"
                    if self.pendingStartPosition > 1 {
                        let target = self.pendingStartPosition
                        self.pendingStartPosition = 0
                        self.player.seek(
                            to: CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
                        ) { _ in
                            if self.intentToPlay { self.play() }
                        }
                    } else if self.intentToPlay {
                        self.play()
                    }
                case .failed:
                    self.statusText = "加载失败：\(item.error?.localizedDescription ?? "未知错误")"
                default:
                    self.statusText = "加载中"
                }
            }
        }
        observeItemNotifications(item)
        player.replaceCurrentItem(with: item)
        statusText = "加载中"
    }

    func play() {
        intentToPlay = true
        player.rate = playbackRate
    }

    func pause() {
        intentToPlay = false
        player.pause()
        onProgress?(currentTime, duration)
    }

    func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
        )
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            pause()
        } else {
            play()
        }
    }

    // MARK: - 自动恢复

    private func observeItemNotifications(_ item: AVPlayerItem) {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        let center = NotificationCenter.default

        // 播放结束：先落一次最终进度，再通知上层（自动连播）
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.duration > 0 {
                self.onProgress?(self.duration, self.duration)
            }
            self.onEnded?()
        })

        // 播放卡顿：等 1 秒让缓冲恢复，再自动续播
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.intentToPlay else { return }
            self.statusText = "网络卡顿，自动恢复中"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.intentToPlay else { return }
                self.play()
            }
        })

        // 系统音频中断（来电 / 其他 App 抢占）：结束后按中断前状态续播
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = self.intentToPlay
            case .ended:
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if self.wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                    self.play()
                }
            @unknown default:
                break
            }
        })
    }
}
