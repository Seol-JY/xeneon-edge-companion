import AppKit
import SwiftUI

/// Discord voice at a glance. Off: a quiet prompt that opens Discord. Idle: (linked) mute controls
/// ready for the next call. On a call: the elapsed time, and when linked in Settings the channel,
/// who is in it and speaking, and mute / deafen / leave.
struct DiscordWidget: View {
  @ObservedObject private var discord = DiscordController.shared
  /// The leave button asks for a second tap.
  @State private var confirmLeave = false
  @State private var confirmWork: DispatchWorkItem?

  static let speakingGreen = Color(red: 0.14, green: 0.65, blue: 0.35)

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let size = geo.size
        Group {
          if !discord.running { offState }
          else if !discord.inCall { idleState(size) }
          else if discord.linked, let call = discord.call { callState(call, size) }
          else { basicCallState(size) }
        }
        .frame(width: size.width, height: size.height)
      }
      // A little more room than other cards; the header and buttons otherwise sit close to the edge.
      .padding(4)
    }
    .onAppear { discord.retain() }
    .onDisappear {
      discord.release()
      resetLeave()
    }
  }

  // MARK: States

  /// Discord closed: a dim Discord mark; tapping opens it.
  private var offState: some View {
    Button { discord.openDiscord() } label: {
      VStack(spacing: 14) {
        DiscordLogo(height: 34)
        Text(tr("Discord 꺼짐", "Discord is off"))
          .font(Theme.text(15, weight: .semibold))
      }
      .foregroundStyle(Theme.textTertiary.opacity(0.8))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
  }

  private func idleState(_ size: CGSize) -> some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      VStack(spacing: 14) {
        DiscordLogo(height: 34)
          .foregroundStyle(Theme.textSecondary)
        Text(tr("통화 중 아님", "Not on a call"))
          .font(Theme.text(15, weight: .semibold))
          .foregroundStyle(Theme.textSecondary)
      }
      Spacer(minLength: 0)
      if discord.linked { controls(size, leave: false) }
    }
  }

  /// On a call but not linked: all we know is that Discord holds the microphone.
  private func basicCallState(_ size: CGSize) -> some View {
    VStack(spacing: 0) {
      header(title: tr("통화 중", "On a call"), server: nil)
      Spacer(minLength: 0)
      ZStack {
        Circle().fill(Self.speakingGreen.opacity(0.14))
        Circle().strokeBorder(Self.speakingGreen.opacity(0.35), lineWidth: 1.5)
        DiscordLogo(height: 32)
          .foregroundStyle(Self.speakingGreen)
      }
      .frame(width: 96, height: 96)
      Spacer(minLength: 0)
      // Balances the header so the circle sits in the middle of the card.
      Color.clear.frame(height: 22)
    }
  }

  private func callState(_ call: DiscordController.Call, _ size: CGSize) -> some View {
    VStack(spacing: 0) {
      header(title: call.name, server: call.guildName)
      GeometryReader { geo in
        roster(call.members, in: geo.size)
          .frame(width: geo.size.width, height: geo.size.height)
      }
      .padding(.vertical, 12)
      controls(size, leave: true)
    }
  }

  // MARK: Pieces

  /// The Discord mark, then "channel / server" on one line, with the elapsed time at the right.
  private func header(title: String, server: String?) -> some View {
    HStack(spacing: 8) {
      DiscordLogo(height: 13)
        .foregroundStyle(Theme.textTertiary)
      (Text(title).foregroundColor(Theme.textPrimary)
        + Text(server.map { "  /  \($0)" } ?? "").foregroundColor(Theme.textTertiary).font(Theme.text(15, weight: .semibold)))
        .font(Theme.text(17, weight: .bold))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 6)
      if let start = discord.callStart {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          HStack(spacing: 5) {
            Circle().fill(Self.speakingGreen).frame(width: 7, height: 7)
            Text(Self.elapsed(context.date.timeIntervalSince(start)))
              .font(Theme.number(14, weight: .semibold))
              .foregroundStyle(Theme.textSecondary)
          }
        }
      }
    }
    .frame(height: 22)
  }

  /// Avatars in rows, as many as fit; the rest collapse into a "+N" bubble.
  private func roster(_ members: [DiscordController.Member], in size: CGSize) -> some View {
    let avatar: CGFloat = min(56, max(38, size.height / 2 - 30))
    let spacing: CGFloat = 14
    let rowHeight = avatar + 26
    let columns = max(1, Int((size.width + spacing) / (avatar + spacing)))
    let rows = max(1, Int((size.height + 8) / (rowHeight + 8)))
    let capacity = columns * rows
    let shown = members.count > capacity ? Array(members.prefix(capacity - 1)) : members
    let extra = members.count - shown.count
    return LazyVGrid(columns: Array(repeating: GridItem(.fixed(avatar), spacing: spacing), count: min(columns, max(members.count, 1))), spacing: 8) {
      ForEach(shown) { member in
        AvatarBubble(member: member, image: discord.avatars[member.id], speaking: discord.speaking.contains(member.id), size: avatar)
      }
      if extra > 0 {
        VStack(spacing: 8) {
          Circle()
            .fill(Color.white.opacity(0.08))
            .frame(width: avatar, height: avatar)
            .overlay(Text("+\(extra)").font(Theme.number(avatar * 0.32, weight: .bold)).foregroundStyle(Theme.textSecondary))
          Text(" ").font(Theme.text(13))
        }
      }
    }
  }

  /// Discord's own controls; only shown when linked. Deafening also mutes in Discord, so the
  /// microphone reads as muted while deafened, and tapping it then undeafens too.
  private func controls(_ size: CGSize, leave: Bool) -> some View {
    let button = min(50, size.height * 0.16)
    let micOff = discord.selfMute || discord.selfDeaf
    return HStack(spacing: 14) {
      CallButton(symbol: micOff ? "mic.slash.fill" : "mic.fill", alert: micOff, size: button) { discord.toggleMute() }
      CallButton(symbol: discord.selfDeaf ? "headphones.slash" : "headphones", alert: discord.selfDeaf, size: button) { discord.toggleDeaf() }
      if leave {
        CallButton(symbol: "phone.down.fill", alert: confirmLeave, glyph: Theme.critical, size: button) { leaveTapped() }
      }
    }
  }

  private func leaveTapped() {
    if confirmLeave {
      resetLeave()
      discord.leave()
      return
    }
    confirmLeave = true
    let work = DispatchWorkItem { confirmLeave = false }
    confirmWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
  }

  private func resetLeave() {
    confirmWork?.cancel()
    confirmWork = nil
    confirmLeave = false
  }

  private static func elapsed(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
  }
}

private struct AvatarBubble: View {
  let member: DiscordController.Member
  let image: NSImage?
  let speaking: Bool
  let size: CGFloat

  var body: some View {
    VStack(spacing: 8) {
      ZStack {
        if let image {
          Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
          Color.white.opacity(0.1)
          Text(member.name.prefix(1).uppercased())
            .font(Theme.text(size * 0.4, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
        }
      }
      .frame(width: size, height: size)
      .clipShape(Circle())
      .opacity(member.deafened ? 0.55 : 1)
      .padding(3)
      .overlay(Circle().strokeBorder(DiscordWidget.speakingGreen, lineWidth: 2.5).opacity(speaking ? 1 : 0))
      .shadow(color: DiscordWidget.speakingGreen.opacity(speaking ? 0.45 : 0), radius: 8)
      .overlay(alignment: .bottomTrailing) {
        if member.muted || member.deafened {
          Image(systemName: member.deafened ? "headphones.slash" : "mic.slash.fill")
            .font(.system(size: size * 0.2, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size * 0.36, height: size * 0.36)
            .background(Circle().fill(Theme.critical))
            .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
        }
      }
      .animation(.easeOut(duration: 0.15), value: speaking)
      .padding(-3)
      Text(member.name)
        .font(Theme.text(13, weight: .semibold))
        .foregroundStyle(speaking ? Theme.textPrimary : Theme.textSecondary)
        .lineLimit(1)
        .frame(width: size + 12)
    }
  }
}

/// A round control; `alert` fills it red for muted, deafened or "tap again to leave".
private struct CallButton: View {
  let symbol: String
  var alert = false
  /// The glyph's colour while not alerting.
  var glyph: Color = Theme.textPrimary
  let size: CGFloat
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size * 0.38, weight: .semibold))
        .foregroundStyle(alert ? Color.white : glyph)
        .frame(width: size, height: size)
        .background(Circle().fill(alert ? Theme.critical : Color.white.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(PressableStyle())
  }
}
