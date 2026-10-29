import EdgeCore
import SwiftUI

/// The second Discord page: two current routes, then an in-card picker for either route.
struct DiscordVoiceDevicesPage: View {
  @ObservedObject var discord: DiscordController
  @State private var picking: DiscordController.VoiceDirection?
  @State private var requestedID: String?

  var body: some View {
    GeometryReader { geo in
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          if picking != nil {
            Button { picking = nil; requestedID = nil } label: {
              Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(Theme.textSecondary)
          } else {
            DiscordLogo(height: 14).foregroundStyle(Theme.textTertiary)
          }
          Text(picking.map(title) ?? tr("음성 장치", "Voice devices"))
            .font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
          Spacer(minLength: 0)
          Button { discord.reloadVoiceDevices() } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
              .frame(width: 30, height: 30).contentShape(Rectangle())
          }
          .buttonStyle(PressableStyle())
          .foregroundStyle(Theme.textTertiary)
          .disabled(discord.updatingVoiceDevices)
          .help(tr("장치 목록 새로고침", "Refresh devices"))
        }
        .frame(height: 30)
        if let picking {
          deviceList(picking)
        } else {
          Spacer(minLength: 0)
          VStack(spacing: 12) {
            routeRow(.output, height: min(78, max(54, (geo.size.height - 90) / 2)))
            routeRow(.input, height: min(78, max(54, (geo.size.height - 90) / 2)))
          }
          Spacer(minLength: 0)
        }
        if let error = discord.voiceDeviceError {
          Text(error).font(Theme.text(11.5)).foregroundStyle(Theme.warning)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }
    .onAppear { discord.reloadVoiceDevices() }
    .onChange(of: discord.updatingVoiceDevices) { _, updating in
      guard !updating, discord.voiceDeviceError == nil, let picking, let requestedID,
            discord.route(picking).selectedID == requestedID else { return }
      self.picking = nil
      self.requestedID = nil
    }
  }

  private func title(_ direction: DiscordController.VoiceDirection) -> String {
    direction == .input ? tr("마이크", "Microphone") : tr("사운드 출력", "Sound output")
  }

  private func name(_ device: DiscordVoiceDevice) -> String {
    device.id == "default" ? tr("시스템 기본값", "System default") : device.name
  }

  private func routeRow(_ direction: DiscordController.VoiceDirection, height: CGFloat) -> some View {
    let route = discord.route(direction)
    let selectedName = route.selected.map(name) ?? (route.selectedID == "default" ? tr("시스템 기본값", "System default") :
      route.selectedID == nil ? (discord.updatingVoiceDevices ? tr("불러오는 중…", "Loading…") : tr("장치 정보 없음", "Device unavailable")) : tr("장치를 확인해 주세요", "Check the device"))
    return Button { picking = direction; requestedID = nil; discord.reloadVoiceDevices() } label: {
      HStack(spacing: 12) {
        Image(systemName: direction == .input ? "mic.fill" : "speaker.wave.2.fill")
          .font(.system(size: 18, weight: .medium)).foregroundStyle(direction == .input ? Theme.cpu : Theme.gpu)
          .frame(width: 26)
        VStack(alignment: .leading, spacing: 5) {
          Text(title(direction)).font(Theme.text(11.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
          Text(selectedName).font(Theme.text(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            .lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
      }
      .padding(.horizontal, 12)
      .frame(height: height)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
  }

  private func deviceList(_ direction: DiscordController.VoiceDirection) -> some View {
    let route = discord.route(direction)
    let tint = direction == .input ? Theme.cpu : Theme.gpu
    return ScrollView {
      VStack(spacing: 7) {
        if route.devices.isEmpty {
          Text(discord.updatingVoiceDevices ? tr("장치를 불러오는 중…", "Loading devices…") : tr("사용 가능한 장치가 없어요", "No devices available"))
            .font(Theme.text(13)).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 70)
        }
        ForEach(route.devices) { device in
          let selected = device.id == route.selectedID
          Button {
            if selected { picking = nil; return }
            requestedID = device.id
            discord.selectVoiceDevice(device, direction: direction)
          } label: {
            HStack(spacing: 8) {
              Text(name(device)).font(Theme.text(13.5, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.leading)
              Spacer(minLength: 2)
              if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
              else if requestedID == device.id, discord.updatingVoiceDevices {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
              }
            }
            .foregroundStyle(selected ? tint : Theme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.08 : 0.04)))
            .contentShape(Rectangle())
          }
          .buttonStyle(PressableStyle())
          .disabled(discord.updatingVoiceDevices)
        }
      }
    }
    .scrollIndicators(.hidden)
    .frame(maxHeight: .infinity)
  }
}
