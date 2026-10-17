import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
  /// Posted when the dashboard stops or starts being visible (TelemetryHub.isSuspended changed).
  static let edgeDashboardSuspensionChanged = Notification.Name("EdgeDashboardSuspensionChanged")
}

/// Files picked for media widgets. Each one is copied into the app's folder, so moving or deleting
/// the original never breaks the widget.
enum MediaLibrary {
  static var folder: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("EdgeCompanion/Media", isDirectory: true)
  }

  static func url(for item: MediaItem) -> URL { folder.appendingPathComponent(item.file) }

  enum Kind { case image, animation, video }

  static func kind(of url: URL) -> Kind {
    let type = UTType(filenameExtension: url.pathExtension.lowercased())
    if let type, type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
    // GIF, animated PNG/WebP/HEIC: anything ImageIO sees as several frames.
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 { return .animation }
    return .image
  }

  /// Asks for a file on the main display and assigns it to the widget in `slotID`.
  static func choose(for slotID: UUID) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .movie]
    panel.allowsMultipleSelection = false
    panel.message = tr("사진, GIF 또는 영상을 골라 주세요", "Choose a photo, GIF or video")
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let source = panel.url else { return }
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let name = "\(slotID.uuidString)-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
      try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
      let store = SettingsStore.shared
      var item = store.settings.mediaItems[slotID.uuidString] ?? MediaItem(file: name, originalName: source.lastPathComponent)
      item.file = name
      item.originalName = source.lastPathComponent
      store.settings.mediaItems[slotID.uuidString] = item
      prune()
    } catch {
      Log.error(.dashboard, "media copy failed: \(error.localizedDescription)")
    }
  }

  /// Drops settings for removed widgets and deletes files nothing uses any more.
  static func prune() {
    let store = SettingsStore.shared
    let live = Set(store.settings.pages.flatMap(\.slots).filter { $0.kind == .media }.map(\.id.uuidString))
    let items = store.settings.mediaItems.filter { live.contains($0.key) }
    if items != store.settings.mediaItems { store.settings.mediaItems = items }
    let used = Set(items.values.map(\.file))
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for file in files where !used.contains(file) {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
    }
  }
}

/// A photo, GIF or video filling the card, repeating forever.
struct MediaWidget: View {
  let slotID: UUID
  @ObservedObject private var store = SettingsStore.shared

  var body: some View {
    let item = store.settings.mediaItems[slotID.uuidString]
    if let item, FileManager.default.fileExists(atPath: MediaLibrary.url(for: item).path) {
      MediaPlayerView(url: MediaLibrary.url(for: item), fill: item.fill)
        .background(Theme.card)
        .overlay(
          RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(Theme.cardBorder, lineWidth: 1)
        )
    } else {
      WidgetCard {
        VStack(alignment: .leading, spacing: 10) {
          Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.textSecondary)
          Text(tr("설정 > 대시보드 > 위젯 배치에서 이 위젯을 눌러 파일을 골라 주세요", "Pick a file: Settings > Dashboard > Widget layout, then click this widget"))
            .font(Theme.text(15, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
  }
}

private struct MediaPlayerView: NSViewRepresentable {
  let url: URL
  let fill: Bool

  func makeNSView(context: Context) -> MediaPlayerNSView { MediaPlayerNSView() }

  func updateNSView(_ view: MediaPlayerNSView, context: Context) {
    view.show(url, fill: fill)
  }

  static func dismantleNSView(_ view: MediaPlayerNSView, coordinator: ()) {
    view.stop()
  }
}

/// Layer-backed player. Video plays muted with hardware decoding and rewinds at its end; animated
/// images become a Core Animation keyframe animation, which the render server plays without waking
/// the app. Everything pauses while the dashboard is hidden, and a tap pauses or resumes it.
final class MediaPlayerNSView: NSView {
  private var current: (url: URL, fill: Bool)?
  private var player: AVPlayer?
  private var endObserver: NSObjectProtocol?
  private var playerLayer: AVPlayerLayer?
  private let imageLayer = CALayer()
  private var animation: CAKeyframeAnimation?
  private var observer: NSObjectProtocol?
  /// Paused by a tap; held across the dashboard hiding and showing again.
  private var userPaused = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = Theme.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    imageLayer.contentsGravity = .resizeAspectFill
    layer?.addSublayer(imageLayer)
    observer = NotificationCenter.default.addObserver(forName: .edgeDashboardSuspensionChanged, object: nil, queue: .main) { [weak self] _ in
      self?.applySuspension()
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  // The Edge panel is never the key window, so the first click has to count.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    userPaused.toggle()
    applySuspension()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = bounds
    playerLayer?.frame = bounds
    CATransaction.commit()
  }

  func show(_ url: URL, fill: Bool) {
    if current?.url == url {
      if current?.fill != fill { setGravity(fill) }
      current = (url, fill)
      return
    }
    stop()
    current = (url, fill)
    switch MediaLibrary.kind(of: url) {
    case .video: startVideo(url)
    case .animation: startAnimation(url)
    case .image: imageLayer.contents = Self.frames(of: url, limit: 1).first?.image
    }
    setGravity(fill)
    applySuspension()
  }

  func stop() {
    player?.pause()
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    player = nil
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    imageLayer.removeAllAnimations()
    imageLayer.contents = nil
    animation = nil
    current = nil
    userPaused = false
    imageLayer.speed = 1
    imageLayer.timeOffset = 0
  }

  private func setGravity(_ fill: Bool) {
    imageLayer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
    playerLayer?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
  }

  private func startVideo(_ url: URL) {
    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.preventsDisplaySleepDuringVideoPlayback = false
    // Rewind by hand rather than with AVPlayerLooper, which never loops fragmented MP4s
    // (YouTube downloads) because their duration isn't known up front. With `.none` the rate stays
    // at 1, so seeking back keeps it playing.
    player.actionAtItemEnd = .none
    endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak player] _ in
      player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    let playerLayer = AVPlayerLayer(player: player)
    playerLayer.frame = bounds
    layer?.addSublayer(playerLayer)
    self.player = player
    self.playerLayer = playerLayer
  }

  private func startAnimation(_ url: URL) {
    let frames = Self.frames(of: url, limit: 600)
    guard !frames.isEmpty else { return }
    imageLayer.contents = frames[0].image
    let total = frames.reduce(0) { $0 + $1.delay }
    var t = 0.0
    var times: [NSNumber] = []
    for f in frames {
      times.append(NSNumber(value: t / total))
      t += f.delay
    }
    let anim = CAKeyframeAnimation(keyPath: "contents")
    anim.values = frames.map(\.image)
    anim.keyTimes = times
    anim.calculationMode = .discrete
    anim.duration = total
    anim.repeatCount = .infinity
    anim.isRemovedOnCompletion = false
    animation = anim
  }

  private func applySuspension() {
    let suspended = TelemetryHub.shared.isSuspended
    if let player {
      if suspended || userPaused { player.pause() } else { player.play() }
    }
    if let animation {
      if suspended { imageLayer.removeAnimation(forKey: "frames") }
      else if imageLayer.animation(forKey: "frames") == nil { imageLayer.add(animation, forKey: "frames") }
      setAnimationPaused(userPaused)
    }
  }

  /// Freezes the animation on its current frame by stopping the layer's clock, and restarts the
  /// clock from there.
  private func setAnimationPaused(_ paused: Bool) {
    if paused, imageLayer.speed != 0 {
      let now = imageLayer.convertTime(CACurrentMediaTime(), from: nil)
      imageLayer.speed = 0
      imageLayer.timeOffset = now
    } else if !paused, imageLayer.speed == 0 {
      let pausedAt = imageLayer.timeOffset
      imageLayer.speed = 1
      imageLayer.timeOffset = 0
      imageLayer.beginTime = 0
      imageLayer.beginTime = imageLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
    }
  }

  /// Frames scaled down to at most 1600 px (the Edge is 2560×720 at 1x), with their delays.
  private static func frames(of url: URL, limit: Int) -> [(image: CGImage, delay: Double)] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 1600,
    ]
    var result: [(CGImage, Double)] = []
    for i in 0 ..< min(CGImageSourceGetCount(source), limit) {
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { continue }
      result.append((image, delay(of: source, at: i)))
    }
    return result
  }

  private static func delay(of source: CGImageSource, at index: Int) -> Double {
    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
    let dicts: [(CFString, CFString, CFString)] = [
      (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
      (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
      (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
    ]
    for (dict, unclamped, clamped) in dicts {
      guard let d = props[dict] as? [CFString: Any] else { continue }
      let value = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
      // Browsers treat very short delays as 0.1 s; so do we.
      return value < 0.02 ? 0.1 : value
    }
    return 0.1
  }
}
