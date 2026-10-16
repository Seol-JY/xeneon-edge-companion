import AppKit
import SwiftUI

/// The clock widget's Apple Music page: artwork, track, a progress bar you can tap to seek, and
/// transport buttons. Lays out side by side in a wide card and stacked in a narrow one.
struct NowPlayingView: View {
  @ObservedObject private var music = MusicController.shared

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      Group {
        if w > h * 1.3 {
          // Reaches a little into the card's top padding and the gap above the page dots.
          wide(w: w, h: h + 14)
            .frame(width: w, height: h + 14)
            .offset(y: -1)
        }
        else if w < 420 { compact(w: w, h: h) }
        else { stacked(w: w, h: h) }
      }
      .frame(width: w, height: h)
    }
  }

  /// 2×1: artwork on the left, everything else beside it.
  private func wide(w: CGFloat, h: CGFloat) -> some View {
    let art = min(h, w * 0.46)
    // The text column is centred vertically within the artwork's height.
    return HStack(spacing: 28) {
      ArtworkTile(side: art)
      VStack(alignment: .leading, spacing: 0) {
        TrackTitle(titleSize: 31, artistSize: 19, lines: 2)
          .padding(.bottom, 24)
        PlaybackProgress()
          .padding(.bottom, 18)
        TransportControls(main: 60)
          .frame(maxWidth: .infinity)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: art, alignment: .center)
    }
    .frame(maxHeight: .infinity)
  }

  /// 1×1: small artwork beside the title, controls underneath.
  private func compact(w: CGFloat, h: CGFloat) -> some View {
    let art = min(w * 0.4, h * 0.4)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .bottom, spacing: 14) {
        ArtworkTile(side: art)
        TrackTitle(titleSize: 19, artistSize: 14.5, lines: 2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 10)
      PlaybackProgress()
      Spacer(minLength: 10)
      TransportControls(main: 50)
        .frame(maxWidth: .infinity)
    }
  }

  /// 1×2 and 2×2: large artwork on top, centred text and controls below.
  private func stacked(w: CGFloat, h: CGFloat) -> some View {
    let art = max(80, min(w * 0.95, h - 220))
    return VStack(spacing: 0) {
      ArtworkTile(side: art)
      Spacer(minLength: 14)
      TrackTitle(titleSize: 26, artistSize: 18, lines: 1, alignment: .center)
      Spacer(minLength: 12)
      PlaybackProgress()
      Spacer(minLength: 12)
      TransportControls(main: 58)
    }
    .frame(maxWidth: .infinity)
  }
}

/// Blurred artwork filling the card behind the player.
struct NowPlayingBackdrop: View {
  @ObservedObject private var music = MusicController.shared

  var body: some View {
    GeometryReader { geo in
      ZStack {
        if let image = music.backdrop {
          Image(nsImage: image)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fill)
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(1.2)   // the blur fades at the image edges
            .clipped()
          // Darken towards the bottom and the text side so any artwork stays readable.
          LinearGradient(colors: [Color.black.opacity(0.24), Color.black.opacity(0.52)], startPoint: .top, endPoint: .bottom)
          LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.16)], startPoint: .leading, endPoint: .trailing)
        } else {
          RadialGradient(colors: [music.accent.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: max(geo.size.width, 300))
        }
      }
    }
    .allowsHitTesting(false)
  }
}

struct ArtworkTile: View {
  let side: CGFloat
  @ObservedObject private var music = MusicController.shared

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: max(8, side * 0.055), style: .continuous)
    ZStack {
      if let art = music.artwork {
        Image(nsImage: art)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fill)
      } else {
        LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
        Image(systemName: "music.note")
          .font(.system(size: side * 0.3, weight: .semibold))
          .foregroundStyle(Color.white.opacity(0.32))
      }
    }
    .frame(width: side, height: side)
    .clipShape(shape)
    .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    .shadow(color: .black.opacity(0.28), radius: side * 0.05, y: side * 0.02)
    // Like the Music app: the cover settles back while paused.
    .scaleEffect(music.state == .paused ? 0.93 : 1)
    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: music.state == .paused)
  }
}

private struct TrackTitle: View {
  let titleSize: CGFloat
  let artistSize: CGFloat
  let lines: Int
  var alignment: HorizontalAlignment = .leading
  @ObservedObject private var music = MusicController.shared

  var body: some View {
    let track = music.track
    let textAlignment: TextAlignment = alignment == .center ? .center : .leading
    VStack(alignment: alignment, spacing: 4) {
      Text(track?.title ?? "Apple Music")
        .font(Theme.text(titleSize, weight: .bold))
        .tracking(-0.3)
        .foregroundStyle(Color.white.opacity(0.97))
        .lineLimit(lines)
        .minimumScaleFactor(0.8)
        .multilineTextAlignment(textAlignment)
      if let artist = track?.artist, !artist.isEmpty {
        Text(artist)
          .font(Theme.text(artistSize, weight: .semibold))
          .foregroundStyle(Color.white.opacity(0.74))
          .lineLimit(1)
      }
    }
    .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
    .fixedSize(horizontal: false, vertical: true)
    .id(track?.key)
    .transition(.opacity.combined(with: .offset(y: 6)))
    .animation(.easeOut(duration: 0.35), value: track?.key)
  }
}

/// Elapsed and remaining time over a thin bar. Ticks once a second, and only while playing.
private struct PlaybackProgress: View {
  @ObservedObject private var music = MusicController.shared

  var body: some View {
    if music.state == .playing {
      TimelineView(.periodic(from: .now, by: 1)) { context in row(music.currentPosition(at: context.date)) }
    } else {
      row(music.currentPosition())
    }
  }

  private func row(_ position: TimeInterval) -> some View {
    let duration = music.track?.duration ?? 0
    let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
    return VStack(spacing: 7) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.16))
          Capsule()
            .fill(Color.white.opacity(music.state == .playing ? 0.92 : 0.6))
            .frame(width: max(5, geo.size.width * fraction))
        }
        .frame(height: 5)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
          music.seek(toFraction: Double(location.x / max(geo.size.width, 1)))
        }
      }
      .frame(height: 18)   // taller than the bar so it is easy to hit
      .padding(.vertical, -6)
      HStack {
        Text(Self.clock(position))
        Spacer()
        if duration > 0 { Text("-" + Self.clock(duration - position)) }
      }
      .font(Theme.number(12.5, weight: .semibold))
      .foregroundStyle(Color.white.opacity(0.52))
    }
    .transaction { $0.animation = nil }
  }

  private static func clock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
  }
}

private struct TransportControls: View {
  let main: CGFloat
  @ObservedObject private var music = MusicController.shared

  var body: some View {
    if music.automationDenied {
      Button {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
          NSWorkspace.shared.open(url)
        }
      } label: {
        Label(tr("Music 제어 권한 켜기", "Allow controlling Music"), systemImage: "lock.fill")
          .font(Theme.text(14, weight: .semibold))
          .foregroundStyle(Color.white.opacity(0.85))
          .padding(.horizontal, 16)
          .frame(height: 40)
          .background(Capsule().fill(Color.white.opacity(0.12)))
          .contentShape(Capsule())
      }
      .buttonStyle(PressableStyle())
    } else {
      HStack(spacing: main * 0.5) {
        TransportButton(symbol: "backward.fill", size: main * 0.8) { music.previous() }
        TransportButton(symbol: music.state == .playing ? "pause.fill" : "play.fill", size: main, primary: true) { music.playPause() }
        TransportButton(symbol: "forward.fill", size: main * 0.8) { music.next() }
      }
    }
  }
}

private struct TransportButton: View {
  let symbol: String
  let size: CGFloat
  var primary = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size * (primary ? 0.6 : 0.46), weight: .bold))
        .foregroundStyle(Color.white.opacity(primary ? 0.96 : 0.86))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        // Only as tall as the glyphs, so the row sits flush with the artwork's bottom edge.
        .frame(width: size, height: size * 0.66)
        .contentShape(Rectangle().inset(by: -10))
    }
    .buttonStyle(PressableStyle())
  }
}
