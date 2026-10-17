import AppKit
import EdgeCore
import SwiftUI

/// Diagnostic: renders widgets to PNG files without touching the dashboard layout.
///   EdgeCompanion --render-widgets <folder> [kind ...] [--cell 492x339] [--music-demo [artwork]]
/// `--music-demo` fills in a playing track so the clock renders its Apple Music page.
@MainActor
enum WidgetRenderer {
  static func run(arguments: [String]) {
    guard let i = arguments.firstIndex(of: "--render-widgets"), arguments.count > i + 1 else {
      print("usage: --render-widgets <folder> [kind ...]")
      return
    }
    let folder = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var cell = CGSize(width: 492, height: 339)
    if let c = arguments.firstIndex(of: "--cell"), arguments.count > c + 1 {
      let parts = arguments[c + 1].split(separator: "x").compactMap { Double($0) }
      if parts.count == 2 { cell = CGSize(width: parts[0], height: parts[1]) }
    }
    let requested = arguments.dropFirst(i + 2).prefix { !$0.hasPrefix("--") }.compactMap(WidgetKind.init(rawValue:))
    var musicDemo = false
    if let m = arguments.firstIndex(of: "--music-demo") ?? arguments.firstIndex(of: "--music-demo-paused") {
      musicDemo = true
      let path = arguments.count > m + 1 && !arguments[m + 1].hasPrefix("--") ? arguments[m + 1] : nil
      MusicController.shared.preview(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                     duration: 243, position: 88, artwork: path.flatMap { NSImage(contentsOfFile: $0) },
                                     paused: arguments[m] == "--music-demo-paused")
    }
    let kinds = requested.isEmpty ? [WidgetKind.timer, .volume] : Array(requested)

    // Widgets that load data on appear need it before an offscreen render.
    AudioController.shared.retain()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    for kind in kinds {
      for size in [WidgetSize.small, .wide] {
        let frame = CGSize(width: cell.width * CGFloat(size.columns) + 12 * CGFloat(size.columns - 1), height: cell.height)
        let slot = WidgetSlot(kind: kind, size: size)
        if musicDemo {
          TilePager.shared.show(slot.id, page: 1)
          RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // the page turns on the next pass
        }
        let view = WidgetHost(slot: slot)
          .frame(width: frame.width, height: frame.height)
          .padding(12)
          .background(Theme.background)
          .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
        let url = folder.appendingPathComponent("\(kind.rawValue)-\(size.rawValue).png")
        try? png.write(to: url)
        print(url.path)
      }
    }
  }
}
