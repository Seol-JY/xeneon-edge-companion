import AppKit
import CoreImage
import SwiftUI

/// What Apple Music is playing. Track and state changes arrive with Music's
/// `com.apple.Music.playerInfo` distributed notification (no permission, no polling). Position,
/// artwork and the transport buttons go through AppleScript, which macOS gates behind a one-time
/// Automation prompt; without it the player still shows the track from the notification.
/// MediaRemote is not used: since macOS 15.4 it needs an entitled helper.
final class MusicController: ObservableObject {
  static let shared = MusicController()

  enum State { case playing, paused, stopped }

  struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    /// Seconds; 0 when unknown (radio).
    var duration: TimeInterval

    var key: String { "\(title)\u{1}\(artist)\u{1}\(album)" }
  }

  @Published private(set) var state: State = .stopped
  @Published private(set) var track: Track?
  @Published private(set) var artwork: NSImage?
  /// Artwork blurred and saturated, drawn behind the player.
  @Published private(set) var backdrop: NSImage?
  /// A bright colour picked from the artwork for the progress bar.
  @Published private(set) var accent = Color.white
  /// Position at `positionDate`; while playing it runs on from there.
  @Published private(set) var position: TimeInterval = 0
  @Published private(set) var positionDate = Date()
  @Published private(set) var automationDenied = false
  /// The player takes priority over the clock: true while playing and for a while after pausing.
  @Published private(set) var featured = false

  var isActive: Bool { state != .stopped }

  private static let bundleID = "com.apple.Music"
  private static let pausedFeatureTime: TimeInterval = 600
  /// NSAppleScript instances are created and run only on this queue.
  private let scriptQueue = DispatchQueue(label: "pro.seol.EdgeCompanion.music", qos: .userInitiated)
  private var started = false
  private var artworkKey: String?
  private var pendingInfo: DispatchWorkItem?
  private var artCache: [String: Art] = [:]
  /// State from a notification or a button wins over AppleScript reads until then: right after a
  /// pause Music can still answer "playing", which made the label flicker.
  private var stateHeldUntil = Date.distantPast
  private var unfeature: DispatchWorkItem?
  private var resync: Timer?

  // MARK: Lifecycle

  func start() {
    guard !started else { return }
    started = true
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(playerInfo(_:)), name: Notification.Name("com.apple.Music.playerInfo"),
      object: nil, suspensionBehavior: .deliverImmediately)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    // Music only posts on changes, so ask once for what is already playing.
    refresh()
  }

  /// Music's notifications are noisy: every track change posts "Stopped" and then "Playing", and a
  /// pause can post Paused/Playing a few times within a second. Only the last one in a short window
  /// counts, and "Stopped" must hold for a while before the player goes away.
  @objc private func playerInfo(_ note: Notification) {
    let info = note.userInfo ?? [:]
    let stopped = (info["Player State"] as? String)?.lowercased() == "stopped"
    pendingInfo?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pendingInfo = nil
      self?.handle(info)
    }
    pendingInfo = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (stopped ? 1.5 : 0.3), execute: work)
  }

  private func handle(_ info: [AnyHashable: Any]) {
    let newState: State
    switch (info["Player State"] as? String)?.lowercased() {
    case "playing": newState = .playing
    case "paused": newState = .paused
    default: newState = .stopped
    }
    guard newState != .stopped else {
      apply(state: .stopped, track: nil, position: 0)
      return
    }
    var next = track
    if let title = info["Name"] as? String {
      next = Track(
        title: title,
        artist: info["Artist"] as? String ?? "",
        album: info["Album"] as? String ?? "",
        duration: ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000)
    }
    stateHeldUntil = Date().addingTimeInterval(2)
    apply(state: newState, track: next, position: nil)
    // The notification carries no position or artwork.
    refresh()
  }

  @objc private func appTerminated(_ note: Notification) {
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    guard app?.bundleIdentifier == Self.bundleID else { return }
    pendingInfo?.cancel()
    pendingInfo = nil
    apply(state: .stopped, track: nil, position: 0)
  }

  private var musicRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
  }

  // MARK: Transport

  func playPause() {
    // Show the change at once; Music's notification confirms it.
    stateHeldUntil = Date().addingTimeInterval(2)
    if state == .playing { apply(state: .paused, track: track, position: currentPosition()) }
    else if state == .paused { apply(state: .playing, track: track, position: position) }
    command("playpause")
  }

  func next() { command("next track") }

  /// Back to the start of the track, or to the previous one when already near the start.
  func previous() {
    command("back track")
    // Restarting the same track posts no notification.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
  }

  func seek(toFraction fraction: Double) {
    guard let duration = track?.duration, duration > 0, !automationDenied else { return }
    let target = duration * min(max(fraction, 0), 1)
    apply(state: state, track: track, position: target)
    command("set player position to \(target)")
  }

  private func command(_ verb: String) {
    guard musicRunning else { return }
    run("tell application id \"\(Self.bundleID)\" to \(verb)") { _ in }
  }

  func currentPosition(at date: Date = Date()) -> TimeInterval {
    var p = position
    if state == .playing { p += date.timeIntervalSince(positionDate) }
    if let d = track?.duration, d > 0 { p = min(p, d) }
    return max(p, 0)
  }

  // MARK: Reading

  private static let snapshotSource = """
  if application id "com.apple.Music" is running then
    tell application id "com.apple.Music"
      with timeout of 3 seconds
        set s to player state
        if s is stopped then return {s}
        try
          set t to current track
          return {s, player position, name of t, artist of t, album of t, duration of t}
        on error
          return {s, player position}
        end try
      end timeout
    end tell
  end if
  return {}
  """

  private static let artworkSource = """
  if application id "com.apple.Music" is running then
    tell application id "com.apple.Music"
      with timeout of 5 seconds
        try
          set t to current track
          set n to name of t
          try
            return {n, raw data of artwork 1 of t}
          end try
          return {n}
        end try
      end timeout
    end tell
  end if
  return missing value
  """

  /// Reads state, track and position, then the artwork if the track changed.
  func refresh() {
    guard musicRunning else {
      apply(state: .stopped, track: nil, position: 0)
      return
    }
    run(Self.snapshotSource) { [weak self] result in
      guard let self, let list = result else { return }
      guard list.numberOfItems > 0, let code = list.atIndex(1)?.enumCodeValue else {
        self.apply(state: .stopped, track: nil, position: 0)
        return
      }
      var state: State = code == Self.fourCC("kPSP") ? .playing : code == Self.fourCC("kPSS") ? .stopped : .paused
      if Date() < self.stateHeldUntil, self.state != .stopped { state = self.state }
      // Between tracks Music briefly reports stopped; the pending notification settles it.
      if state == .stopped, self.pendingInfo != nil { return }
      let position = list.numberOfItems >= 2 ? list.atIndex(2)?.doubleValue : nil
      var track = self.track
      if list.numberOfItems >= 6, let title = list.atIndex(3)?.stringValue {
        track = Track(
          title: title,
          artist: list.atIndex(4)?.stringValue ?? "",
          album: list.atIndex(5)?.stringValue ?? "",
          duration: list.atIndex(6)?.doubleValue ?? 0)
      }
      self.apply(state: state, track: state == .stopped ? nil : track, position: position)
    }
  }

  private typealias Art = (image: NSImage, backdrop: NSImage?, accent: Color)

  /// Music's own artwork first. Tracks streamed from Apple Music often have none, or get it only
  /// a few seconds in, so try again once and then look the cover up in Apple's iTunes Search API.
  private func loadArtwork(for track: Track, attempt: Int = 0) {
    let key = track.key
    if let cached = artCache[key] {
      show(cached, for: key)
      return
    }
    run(Self.artworkSource, decode: { descriptor -> Art? in
      // Decoding, blurring and sampling stay off the main thread.
      guard let list = descriptor, list.numberOfItems >= 2, list.atIndex(1)?.stringValue == track.title,
            let data = list.atIndex(2)?.data else { return nil }
      return Self.makeArt(data)
    }) { [weak self] art in
      guard let self, self.track?.key == key else { return }
      if let art {
        self.show(art, for: key)
      } else if attempt == 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
          guard self?.track?.key == key else { return }
          self?.loadArtwork(for: track, attempt: 1)
        }
      } else {
        Log.info(.dashboard, "music: no artwork from Music for \"\(track.title)\", searching")
        self.searchArtwork(for: track)
      }
    }
  }

  /// Searches the local storefront, then the US one: some regions (Korea) have no iTunes music
  /// store and return nothing, while the US store knows the same releases under English titles.
  private func searchArtwork(for track: Track, countries: [String]? = nil) {
    let key = track.key
    let region = Locale.current.region?.identifier ?? "US"
    var remaining = countries ?? (region == "US" ? ["US"] : [region, "US"])
    guard !remaining.isEmpty else {
      giveUpArtwork(for: key)
      return
    }
    let country = remaining.removeFirst()
    var components = URLComponents(string: "https://itunes.apple.com/search")!
    components.queryItems = [
      URLQueryItem(name: "term", value: "\(track.artist) \(track.title)"),
      URLQueryItem(name: "media", value: "music"),
      URLQueryItem(name: "entity", value: "song"),
      URLQueryItem(name: "limit", value: "15"),
      URLQueryItem(name: "country", value: country),
    ]
    guard let url = components.url else { return }
    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data, let cover = Self.bestCover(in: data, for: track) else {
        DispatchQueue.main.async {
          guard let self, self.track?.key == key else { return }
          self.searchArtwork(for: track, countries: remaining)
        }
        return
      }
      URLSession.shared.dataTask(with: cover) { data, _, _ in
        let art = data.flatMap(Self.makeArt)
        DispatchQueue.main.async {
          guard let self, self.track?.key == key else { return }
          if let art { self.show(art, for: key) } else { self.giveUpArtwork(for: key) }
        }
      }.resume()
    }.resume()
  }

  /// The search hit that is surely this track, as a 600 px cover URL. A wrong cover is worse than
  /// none, so an unclear result gives nil.
  private static func bestCover(in data: Data, for track: Track) -> URL? {
    struct Response: Decodable {
      struct Item: Decodable {
        var trackName: String?
        var artistName: String?
        var collectionName: String?
        var collectionId: Int?
        var artworkUrl100: String?
        var trackTimeMillis: Double?
      }
      var results: [Item]
    }
    guard let items = try? JSONDecoder().decode(Response.self, from: data).results.filter({ $0.artworkUrl100 != nil }),
          !items.isEmpty else { return nil }
    func norm(_ s: String?) -> String {
      (s ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
    }
    let title = norm(track.title), artist = norm(track.artist), album = norm(track.album)
    func titleMatch(_ item: Response.Item) -> Bool { norm(item.trackName) == title }
    func artistMatch(_ item: Response.Item) -> Bool {
      let a = norm(item.artistName)
      return !artist.isEmpty && !a.isEmpty && (a.contains(artist) || artist.contains(a))
    }
    func namesMatch(_ item: Response.Item) -> Bool {
      titleMatch(item) || artistMatch(item) || (!album.isEmpty && norm(item.collectionName) == album)
    }
    // Music rounds the first length it reports to whole seconds.
    func lengthMatch(_ item: Response.Item) -> Bool {
      guard track.duration > 0, let ms = item.trackTimeMillis else { return false }
      return abs(ms / 1000 - track.duration) < 1.5
    }

    let chosen: Response.Item?
    if let sure = items.first(where: { namesMatch($0) && lengthMatch($0) }) {
      chosen = sure
    } else if track.duration <= 0 {
      chosen = items.first { titleMatch($0) && artistMatch($0) }
    } else {
      // Names translated by the store (Korean titles show in English): trust the length only when
      // every hit of that length is on the same release, so they share one cover.
      let sameLength = items.filter(lengthMatch)
      chosen = Set(sameLength.compactMap(\.collectionId)).count == 1 ? sameLength.first : nil
    }
    guard let small = chosen?.artworkUrl100 else { return nil }
    return URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
  }

  private static func makeArt(_ data: Data) -> Art? {
    guard !data.isEmpty, let image = NSImage(data: data),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return (image, makeBackdrop(cg), accentColor(cg))
  }

  private func show(_ art: Art, for key: String) {
    guard track?.key == key else { return }
    artCache[key] = art
    if artCache.count > 30, let old = artCache.keys.first(where: { $0 != key }) { artCache[old] = nil }
    withAnimation(.easeInOut(duration: 0.45)) {
      artwork = art.image
      backdrop = art.backdrop
      accent = art.accent
    }
  }

  private func giveUpArtwork(for key: String) {
    guard track?.key == key else { return }
    Log.info(.dashboard, "music: no artwork found")
    withAnimation(.easeInOut(duration: 0.45)) {
      artwork = nil
      backdrop = nil
      accent = .white
    }
  }

  // MARK: State

  private func apply(state newState: State, track newTrack: Track?, position newPosition: TimeInterval?) {
    if let p = newPosition {
      position = p
      positionDate = Date()
    } else if newState != state {
      // Keep the bar where it is across a play/pause change until Music reports the position.
      position = currentPosition()
      positionDate = Date()
    }
    if newTrack != track { track = newTrack }
    if newState != state { state = newState }

    let key = newTrack?.key
    if key != artworkKey {
      artworkKey = key
      if let newTrack {
        // The previous cover stays until the new one arrives, so the card never flashes empty.
        loadArtwork(for: newTrack)
      } else {
        artwork = nil
        backdrop = nil
        accent = .white
      }
    }
    updateFeatured()
    updateResync()
  }

  private func updateFeatured() {
    switch state {
    case .playing:
      unfeature?.cancel()
      unfeature = nil
      if !featured { featured = true }
    case .stopped:
      unfeature?.cancel()
      unfeature = nil
      if featured { featured = false }
    case .paused:
      guard featured, unfeature == nil else { return }
      let work = DispatchWorkItem { [weak self] in
        self?.unfeature = nil
        if self?.state == .paused { self?.featured = false }
      }
      unfeature = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.pausedFeatureTime, execute: work)
    }
  }

  /// Seeking in Music posts nothing, so re-read the position now and then while playing.
  private func updateResync() {
    let wanted = state == .playing && !automationDenied
    if wanted, resync == nil {
      resync = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
      resync?.tolerance = 3
    } else if !wanted, let timer = resync {
      timer.invalidate()
      resync = nil
    }
  }

  // MARK: AppleScript

  private func run(_ source: String, completion: @escaping (NSAppleEventDescriptor?) -> Void) {
    run(source, decode: { $0 }, completion: completion)
  }

  private func run<T>(_ source: String, decode: @escaping (NSAppleEventDescriptor?) -> T?, completion: @escaping (T?) -> Void) {
    scriptQueue.async { [weak self] in
      var error: NSDictionary?
      let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
      let code = error?[NSAppleScript.errorNumber] as? Int
      if let code, let message = error?[NSAppleScript.errorMessage] as? String {
        Log.debug(.dashboard, "music script error \(code): \(message)")
      }
      let value = error == nil ? decode(result) : nil
      DispatchQueue.main.async {
        guard let self else { return }
        // -1743: the user turned Automation off for Music.
        let denied = code == -1743
        if denied != self.automationDenied {
          self.automationDenied = denied
          self.updateResync()
          // Allowed again in System Settings: fetch what was missed.
          if !denied, self.artwork == nil, let track = self.track { self.loadArtwork(for: track) }
        }
        completion(value)
      }
    }
  }

  private static func fourCC(_ s: String) -> OSType {
    s.utf8.reduce(0) { $0 << 8 | OSType($1) }
  }

  // MARK: Artwork processing

  private static let ciContext = CIContext(options: [.cacheIntermediates: false])

  private static func makeBackdrop(_ cg: CGImage) -> NSImage? {
    let input = CIImage(cgImage: cg)
    let scale = 180 / max(input.extent.width, input.extent.height, 1)
    let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let output = small.clampedToExtent()
      .applyingGaussianBlur(sigma: 16)
      .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5, kCIInputBrightnessKey: -0.06])
      .cropped(to: small.extent)
    guard let out = ciContext.createCGImage(output, from: small.extent) else { return nil }
    return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
  }

  /// The artwork's most vivid colour, lifted so it reads on a dark card; white for greyscale art.
  private static func accentColor(_ cg: CGImage) -> Color {
    let side = 20
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return .white }
    var r = 0.0, g = 0.0, b = 0.0, total = 0.0
    for i in stride(from: 0, to: pixels.count, by: 4) {
      let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
      let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
      let saturation = hi > 0 ? (hi - lo) / hi : 0
      // Vivid, reasonably bright pixels decide the colour.
      let weight = saturation * saturation * hi + 0.002
      r += pr * weight; g += pg * weight; b += pb * weight; total += weight
    }
    let picked = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    picked.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
    guard s > 0.15 else { return Color(white: 0.92) }
    return Color(nsColor: NSColor(hue: h, saturation: min(max(s, 0.45), 0.75), brightness: max(v, 0.9), alpha: 1))
  }
}
