import Flutter
import UIKit
import DuanjuCore
import CFNetwork
import AVFoundation
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var originalBrightness: CGFloat?
  private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
  private var mediaControls: MediaControls?

  private var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private var screen: UIScreen? { keyWindow?.screen }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ZgjEnsureCoreLinked()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MediaControls") {
      mediaControls = MediaControls(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceSettings") {
      let channel = FlutterMethodChannel(name: "duanju/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "battery" {
          let device = UIDevice.current
          device.isBatteryMonitoringEnabled = true
          guard device.batteryLevel >= 0 else {
            result(nil)
            return
          }
          result(["level": Int((device.batteryLevel * 100).rounded()),
                  "charging": device.batteryState == .charging || device.batteryState == .full])
          return
        }
        let arguments = call.arguments as? [String: Any]
        switch call.method {
        case "getBrightness":
          result(self.screen.map { Double($0.brightness) })
          return
        case "setBrightness":
          guard let screen = self.screen, let value = arguments?["brightness"] as? Double else {
            result(nil)
            return
          }
          if self.originalBrightness == nil { self.originalBrightness = screen.brightness }
          screen.brightness = CGFloat(min(max(value, 0.01), 1))
          result(true)
          return
        case "resetBrightness":
          if let original = self.originalBrightness { self.screen?.brightness = original }
          self.originalBrightness = nil
          result(true)
          return
        case "volume":
          result(Double(AVAudioSession.sharedInstance().outputVolume))
          return
        case "setVolume":
          if let value = arguments?["volume"] as? Double {
            if self.volumeView.superview == nil { self.keyWindow?.addSubview(self.volumeView) }
            let slider = self.volumeView.subviews.first { $0 is UISlider } as? UISlider
            slider?.value = Float(min(max(value, 0), 1))
          }
          result(nil)
          return
        default:
          break
        }
        guard call.method == "systemProxy" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        func address(_ prefix: String) -> String {
          guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                let host = settings["\(prefix)Proxy"] as? String,
                let port = settings["\(prefix)Port"] as? NSNumber,
                !host.isEmpty, port.intValue > 0 else { return "" }
          let name = host.contains(":") ? "[\(host)]" : host
          return "http://\(name):\(port.intValue)"
        }
        let http = address("HTTP")
        let https = address("HTTPS")
        result(["http": http, "https": https.isEmpty ? http : https,
                "bypass": settings["ExceptionsList"] as? [String] ?? [],
                "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
      }
    }
    if let glassRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "LvguoNativeGlass") {
      glassRegistrar.register(NativeGlassViewFactory(messenger: glassRegistrar.messenger()), withId: "lvguo/native_glass")
    }
  }
}

final class MediaControls {
  private let channel: FlutterMethodChannel
  private var targets: [(MPRemoteCommand, Any)] = []
  private var observers: [NSObjectProtocol] = []
  private var artworkPath = ""
  private var artwork: MPMediaItemArtwork?
  private var playing = false
  private var resumeAfterInterruption = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "duanju/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "update":
        self?.update(call.arguments as? [String: Any] ?? [:])
      case "clear":
        self?.clear()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, !self.targets.isEmpty,
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      if type == .began {
        self.resumeAfterInterruption = self.playing
        if self.playing { self.send("pause") }
        return
      }
      let options = AVAudioSession.InterruptionOptions(
        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      if self.resumeAfterInterruption && options.contains(.shouldResume) { self.send("play") }
      self.resumeAfterInterruption = false
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, self.playing,
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
      self.send("pause")
    })
  }

  private func send(_ command: String, positionMs: Double? = nil) {
    var arguments: [String: Any] = ["command": command]
    if let positionMs { arguments["positionMs"] = positionMs }
    channel.invokeMethod("command", arguments: arguments)
  }

  private func bind(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> Void) {
    let token = command.addTarget { event in
      handler(event)
      return .success
    }
    targets.append((command, token))
  }

  private func update(_ args: [String: Any]) {
    let commands = MPRemoteCommandCenter.shared()
    if targets.isEmpty {
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .moviePlayback)
      try? session.setActive(true)
      bind(commands.playCommand) { [weak self] _ in self?.send("play") }
      bind(commands.pauseCommand) { [weak self] _ in self?.send("pause") }
      bind(commands.togglePlayPauseCommand) { [weak self] _ in self?.send("toggle") }
      bind(commands.nextTrackCommand) { [weak self] _ in self?.send("next") }
      bind(commands.previousTrackCommand) { [weak self] _ in self?.send("previous") }
      bind(commands.changePlaybackPositionCommand) { [weak self] event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
        self?.send("seek", positionMs: event.positionTime * 1000)
      }
    }
    playing = args["playing"] as? Bool ?? false
    commands.previousTrackCommand.isEnabled = args["hasPrevious"] as? Bool ?? false
    commands.nextTrackCommand.isEnabled = args["hasNext"] as? Bool ?? false
    let path = args["artwork"] as? String ?? ""
    if path != artworkPath {
      artworkPath = path
      artwork = path.isEmpty ? nil : UIImage(contentsOfFile: path).map { image in
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
    }
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
    let duration = ((args["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "",
      MPMediaItemPropertyArtist: args["subtitle"] as? String ?? "",
      MPNowPlayingInfoPropertyElapsedPlaybackTime: ((args["positionMs"] as? NSNumber)?.doubleValue ?? 0) / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
  }

  private func clear() {
    for (command, token) in targets { command.removeTarget(token) }
    targets.removeAll()
    playing = false
    resumeAfterInterruption = false
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
  }
}

// MARK: - Native Liquid Glass (iOS 26+ UIGlassEffect, fallback UIBlurEffect)
//
// Dart 侧 AdaptiveGlass（lib/ui/widgets/native_glass.dart）通过 PlatformView
// 嵌这个原生玻璃视图：iOS 26+ 用系统 UIGlassEffect，老系统用 UIBlurEffect。
// 视图本身不接收手势（isUserInteractionEnabled = false），点击由上层 Flutter 处理。
// 放在本文件而不是单独的 .swift 文件，是为了不改 Runner.xcodeproj 的
// PBXBuildFile 列表（新文件要手工加进工程才会编译）。

final class NativeGlassViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let style = (args as? [String: Any])?["style"] as? String
    return NativeGlassView(frame: frame, style: style ?? "regular")
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class NativeGlassView: NSObject, FlutterPlatformView {
  private let container: UIView

  init(frame: CGRect, style: String) {
    let container = UIView(frame: frame)
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    self.container = container
    super.init()
    let effectView: UIVisualEffectView
    if #available(iOS 26.0, *) {
      let glassStyle: UIGlassEffect.Style = style == "clear" ? .clear : .regular
      effectView = UIVisualEffectView(effect: UIGlassEffect(style: glassStyle))
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    }
    effectView.frame = container.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.isUserInteractionEnabled = false
    container.addSubview(effectView)
  }

  func view() -> UIView {
    container
  }
}
