import AVKit
import Flutter
import UIKit

@available(iOS 15.0, *)
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate,
    AVPictureInPictureSampleBufferPlaybackDelegate {
  private let channel: FlutterMethodChannel
  private let layer = AVSampleBufferDisplayLayer()
  private lazy var controller = AVPictureInPictureController(contentSource: .init(
    sampleBufferDisplayLayer: layer,
    playbackDelegate: self
  ))
  private var pool: CVPixelBufferPool?
  private var dimensions: CGSize = .zero
  private(set) var selectedHandle: Int64?
  private var playing = false
  private var starting = false
  private var hasFrame = false
  private var possibleObservation: NSKeyValueObservation?
  // 画中画左上角的集数标签（如“第3集”），只画在喂给画中画的帧上，
  // 主播放器画面不受影响。图片按（文字，帧高）缓存，文字变化时重绘。
  private var episodeLabelText: String?
  private var episodeLabelImage: CGImage?
  private var episodeLabelHeight: Int = 0
  private let episodeLabelLock = NSLock()

  var possible: Bool { selectedHandle != nil && hasFrame && controller.isPictureInPicturePossible }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    layer.videoGravity = .resizeAspect
    controller.delegate = self
    controller.requiresLinearPlayback = true
    possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.publishAvailability() }
    }
  }

  func update(handle: Int64?, playing: Bool, autoEnter: Bool) {
    if self.selectedHandle != handle {
      if self.selectedHandle == nil, handle != nil {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
      }
      self.selectedHandle = handle
      if controller.isPictureInPictureActive {
        // 画中画已在播放时切集（预开的下一集换台）：保留窗口里的最后一帧，
        // 等新播放器的帧到来再续上，不黑屏、不断开。
        // 未进入画中画时仍按旧逻辑清空，避免进画中画时看到旧帧。
      } else {
        hasFrame = false
        layer.flushAndRemoveImage()
      }
      controller.invalidatePlaybackState()
      publishAvailability()
    }
    if handle == nil {
      setEpisodeLabel(nil)
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      if controller.isPictureInPictureActive {
        controller.stopPictureInPicture()
      } else if !starting {
        layer.flushAndRemoveImage()
        layer.removeFromSuperlayer()
      }
      return
    }
    controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter
    if self.playing != playing {
      self.playing = playing
      controller.invalidatePlaybackState()
    }
    attachLayer()
  }

  // Dart 侧随播放状态下发的当前集数（如“第3集”），nil 表示不显示。
  // 只存文字，图片在 copyFrame（喂帧线程）里按帧高懒渲染，避免跨线程共享图片。
  func setEpisodeLabel(_ label: String?) {
    episodeLabelLock.lock()
    defer { episodeLabelLock.unlock() }
    guard episodeLabelText != label else { return }
    episodeLabelText = label
    episodeLabelImage = nil
  }

  private func renderEpisodeLabel(_ text: String, frameHeight: Int) -> CGImage? {
    // 标签高约帧高的 5%，字号约为标签高的 58%，左上角小圆角黑底白字。
    let labelHeight = max(24, Int(Double(frameHeight) * 0.05))
    let fontSize = CGFloat(labelHeight) * 0.58
    let font = UIFont.boldSystemFont(ofSize: fontSize)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.white,
    ]
    let textSize = (text as NSString).size(withAttributes: attributes)
    let padX = CGFloat(labelHeight) * 0.45
    let width = Int(ceil(textSize.width + padX * 2))
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: width, height: labelHeight)
    )
    let image = renderer.image { _ in
      let background = UIBezierPath(
        roundedRect: CGRect(x: 0, y: 0, width: width, height: labelHeight),
        cornerRadius: CGFloat(labelHeight) * 0.4
      )
      UIColor.black.withAlphaComponent(0.45).setFill()
      background.fill()
      (text as NSString).draw(
        at: CGPoint(x: padX, y: (CGFloat(labelHeight) - textSize.height) / 2),
        withAttributes: attributes
      )
    }
    return image.cgImage
  }

  // 把集数标签画到已拷贝好的画中画帧的左上角。32BGRA 缓冲对应
  // premultipliedFirst + byteOrder32Little。注意：CGContext 的坐标原点在
  // 左下角（y 向上），而视频帧内存是上到下（第 0 行就是画面顶部）；
  // CGContextDrawImage 是按 CG 坐标把图画正的，所以直接把图画在顶部
  // 的 CG 矩形里（y = height - margin - labelHeight），文字就是正的。
  // 千万不要翻转坐标系——之前 translate + scale(1,-1) 的翻转正是字
  // 上下颠倒的原因：翻转后图的顶边落到了内存里偏下的行，字就倒过来了。
  private func drawEpisodeLabel(into buffer: CVPixelBuffer, width: Int, height: Int) {
    episodeLabelLock.lock()
    let text = episodeLabelText
    var image = episodeLabelImage
    let cachedHeight = episodeLabelHeight
    episodeLabelLock.unlock()
    guard let text else { return }
    if image == nil || cachedHeight != height {
      image = renderEpisodeLabel(text, frameHeight: height)
      episodeLabelLock.lock()
      episodeLabelImage = image
      episodeLabelHeight = height
      episodeLabelLock.unlock()
    }
    guard let image, let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let context = CGContext(
      data: base,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return }
    let labelHeight = max(24, Int(Double(height) * 0.05))
    let scale = Double(labelHeight) / Double(image.height)
    let labelWidth = Int(Double(image.width) * scale)
    let margin = max(8, Int(Double(height) * 0.02))
    context.draw(
      image,
      in: CGRect(x: margin, y: height - margin - labelHeight, width: labelWidth, height: labelHeight)
    )
  }

  private func attachLayer() {
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }),
      let root = window.rootViewController?.view,
      let parent = root.layer.superlayer else { return }
    if layer.superlayer !== parent {
      // 插到窗口图层的最底层，而不是 root.layer 正下方：保证它永远在
      // 全部应用内容之后。之前插在 root.layer 下方时，画中画回前台的
      // 恢复过渡里它可能被别的图层盖到上面，旧帧（带集数角标）就漏
      // 出来，上面叠一张小画面。图层本身只是画中画的内容源，放在
      // 最底层不影响画中画窗口取帧。
      parent.insertSublayer(layer, at: 0)
    }
    layer.frame = root.layer.frame
  }

  func start() -> Bool {
    guard possible else { return false }
    starting = true
    controller.startPictureInPicture()
    return true
  }

  func stop() {
    if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
  }

  private func publishAvailability() {
    channel.invokeMethod("pictureInPicturePossible", arguments: possible)
  }

  func needsFrame(handle: Int64) -> Bool {
    self.selectedHandle == handle && (!hasFrame || starting || controller.isPictureInPictureActive)
  }

  func enqueue(_ source: CVPixelBuffer, handle: Int64, refresh: Bool = false) {
    guard self.selectedHandle == handle, refresh || needsFrame(handle: handle) else { return }
    if layer.superlayer == nil { attachLayer() }
    if layer.status == .failed { layer.flush() }
    guard layer.isReadyForMoreMediaData, let buffer = copyFrame(source) else { return }
    CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelIsOpaque, kCFBooleanTrue, .shouldPropagate)
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format
    ) == noErr, let format else { return }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample
    ) == noErr, let sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
       let entry = CFArrayGetValueAtIndex(attachments, 0) {
      let dictionary = unsafeBitCast(entry, to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    layer.enqueue(sample)
    if !hasFrame {
      hasFrame = true
      controller.invalidatePlaybackState()
      publishAvailability()
    }
  }

  // AVKit may retain a sample after mpv has recycled its render buffer.
  private func copyFrame(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let size = CGSize(width: width, height: height)
    if dimensions != size {
      dimensions = size
      pool = nil
    }
    if pool == nil {
      let attributes: [String: Any] = [
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }
    guard let pool else { return nil }
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
    var destination: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      kCFAllocatorDefault, pool, limits, &destination
    ) == kCVReturnSuccess, let destination else { return nil }
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }
    guard let from = CVPixelBufferGetBaseAddress(source),
          let to = CVPixelBufferGetBaseAddress(destination) else { return nil }
    let sourceStride = CVPixelBufferGetBytesPerRow(source)
    let targetStride = CVPixelBufferGetBytesPerRow(destination)
    for row in 0..<height {
      let input = from.advanced(by: row * sourceStride)
      let output = to.advanced(by: row * targetStride)
      memcpy(output, input, width * 4)
    }
    drawEpisodeLabel(into: destination, width: width, height: height)
    return destination
  }

  func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    starting = true
    channel.invokeMethod("pictureInPicturePending", arguments: nil)
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    starting = false
    if selectedHandle == nil {
      controller.stopPictureInPicture()
      return
    }
    channel.invokeMethod("pictureInPictureChanged", arguments: ["active": true])
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
  ) {
    finish()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    finish()
  }

  private func finish() {
    starting = false
    // 画中画停了就把图层摘掉并清掉最后一帧：图层里留的是画中画那帧
    //（带集数角标），之前只要播放页还活着、图层就一直挂着旧帧，回
    // 前台的恢复过渡里它一漏出来，上面就叠一张带角标的小画面。
    // 摘掉后 hasFrame 保持 true（画中画仍可进），下次进画中画或
    // 切集时再由 enqueue/update 重新挂上并喂帧；空图层本身不显示
    // 内容，挂回去也不怕。
    layer.flushAndRemoveImage()
    layer.removeFromSuperlayer()
    channel.invokeMethod("pictureInPictureChanged", arguments: ["active": false])
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
  ) {
    completion(selectedHandle != nil)
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    channel.invokeMethod("pictureInPictureAction", arguments: ["action": playing ? "play" : "pause"])
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    !playing
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    hasFrame ? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) : .invalid
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}
