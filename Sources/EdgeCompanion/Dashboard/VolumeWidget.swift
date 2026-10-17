import AudioToolbox
import CoreAudio
import SwiftUI

/// Output volume, mute and output device through CoreAudio. Updates come from CoreAudio property
/// listeners (no polling) and only while a volume widget is on screen.
final class AudioController: ObservableObject {
  static let shared = AudioController()

  struct Device: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
  }

  @Published private(set) var device: Device?
  @Published private(set) var volume: Float?   // nil: the device has no software volume
  @Published private(set) var muted = false
  @Published private(set) var outputs: [Device] = []

  private var users = 0
  private var listenedDevice: AudioDeviceID?
  private let queue = DispatchQueue.main

  private lazy var systemListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshAll() }
  private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshLevels() }

  func retain() {
    users += 1
    guard users == 1 else { return }
    var defaultAddr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    var devicesAddr = Self.address(kAudioHardwarePropertyDevices)
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, queue, systemListener)
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, queue, systemListener)
    refreshAll()
  }

  func release() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    var defaultAddr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    var devicesAddr = Self.address(kAudioHardwarePropertyDevices)
    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, queue, systemListener)
    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, queue, systemListener)
    stopDeviceListeners()
  }

  // MARK: Actions

  func setVolume(_ value: Float) {
    guard let id = device?.id else { return }
    var v = min(max(value, 0), 1)
    var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    if muted, v > 0 { setMuted(false) }
    refreshLevels()
  }

  func step(_ delta: Float) {
    setVolume((volume ?? 0) + delta)
  }

  func setMuted(_ on: Bool) {
    guard let id = device?.id else { return }
    var value: UInt32 = on ? 1 : 0
    var addr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    refreshLevels()
  }

  func select(_ output: Device) {
    var id = output.id
    var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
  }

  // MARK: Reading

  private func refreshAll() {
    outputs = Self.outputDevices()
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 {
      device = Device(id: id, name: Self.name(of: id))
      startDeviceListeners(id)
    } else {
      device = nil
    }
    refreshLevels()
  }

  private func refreshLevels() {
    guard let id = device?.id else {
      volume = nil
      return
    }
    var v = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    volume = AudioObjectHasProperty(id, &addr) && AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    var m = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    var muteAddr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    muted = AudioObjectHasProperty(id, &muteAddr) && AudioObjectGetPropertyData(id, &muteAddr, 0, nil, &size, &m) == noErr && m != 0
  }

  private func startDeviceListeners(_ id: AudioDeviceID) {
    guard listenedDevice != id else { return }
    stopDeviceListeners()
    for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
      var addr = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
      AudioObjectAddPropertyListenerBlock(id, &addr, queue, deviceListener)
    }
    listenedDevice = id
  }

  private func stopDeviceListeners() {
    guard let id = listenedDevice else { return }
    for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
      var addr = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
      AudioObjectRemovePropertyListenerBlock(id, &addr, queue, deviceListener)
    }
    listenedDevice = nil
  }

  private static func outputDevices() -> [Device] {
    var size = UInt32(0)
    var addr = address(kAudioHardwarePropertyDevices)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter(hasOutput).map { Device(id: $0, name: name(of: $0)) }
  }

  private static func hasOutput(_ id: AudioDeviceID) -> Bool {
    var size = UInt32(0)
    var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
    return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
  }

  private static func name(of id: AudioDeviceID) -> String {
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = address(kAudioObjectPropertyName)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else { return "?" }
    return value as String
  }

  private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }
}

/// Page 1: volume of the current output with mute and ±. Page 2: pick the output device.
struct VolumeWidget: View {
  let id: UUID
  @ObservedObject private var audio = AudioController.shared

  var body: some View {
    PagedCard(id: id, count: 2) { page in
      if page == 0 { levelPage } else { devicePage }
    }
    .onAppear { audio.retain() }
    .onDisappear { audio.release() }
  }

  private var levelPage: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Image(systemName: speakerSymbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gpu)
        Text(audio.device?.name ?? tr("출력 장치 없음", "No output")).font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.textSecondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if let volume = audio.volume {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
          Text("\(Int((volume * 100).rounded()))").font(Theme.number(46, weight: .bold))
          Text("%").font(Theme.number(20, weight: .semibold)).opacity(0.7)
        }
        .foregroundStyle(audio.muted ? Theme.textTertiary : Theme.textPrimary)
        TapBar(value: Double(volume), tint: audio.muted ? Theme.textTertiary : Theme.gpu) { audio.setVolume(Float($0)) }
          .frame(height: 22)
        HStack(spacing: 10) {
          RoundButton(symbol: audio.muted ? "speaker.slash.fill" : "speaker.fill", active: audio.muted) { audio.setMuted(!audio.muted) }
          Spacer()
          RoundButton(symbol: "minus") { audio.step(-0.0625) }
          RoundButton(symbol: "plus") { audio.step(0.0625) }
        }
      } else {
        Text(tr("이 장치는 볼륨을 조절할 수 없어요", "This device has no volume control")).font(Theme.text(14)).foregroundStyle(Theme.textTertiary)
      }
      Spacer(minLength: 0)
    }
  }

  private var devicePage: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(tr("출력 장치", "Output")).font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
      ForEach(audio.outputs.prefix(5)) { output in
        Button { audio.select(output) } label: {
          HStack {
            Text(output.name).font(Theme.text(14, weight: .medium)).lineLimit(1)
            Spacer()
            if output.id == audio.device?.id { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
          }
          .foregroundStyle(output.id == audio.device?.id ? Theme.gpu : Theme.textPrimary)
          .padding(.horizontal, 12)
          .frame(height: 38)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(output.id == audio.device?.id ? 0.08 : 0.04)))
          .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
      }
    }
  }

  private var speakerSymbol: String {
    guard let v = audio.volume, !audio.muted, v > 0 else { return "speaker.slash.fill" }
    return v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
  }
}

/// A level bar you set by tapping where you want it (touch drags scroll, so no thumb to drag).
struct TapBar: View {
  let value: Double
  let tint: Color
  let set: (Double) -> Void

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.track)
        Capsule().fill(tint).frame(width: max(geo.size.height, geo.size.width * CGFloat(min(max(value, 0), 1))))
      }
      .contentShape(Rectangle())
      .onTapGesture(coordinateSpace: .local) { location in
        set(Double(min(max(location.x / geo.size.width, 0), 1)))
      }
    }
    .animation(nil, value: value)
  }
}

/// Round touch button used by the timer and volume widgets.
struct RoundButton: View {
  let symbol: String
  var active = false
  var size: CGFloat = 46
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size * 0.38, weight: .semibold))
        .foregroundStyle(active ? Theme.background : Theme.textPrimary)
        .frame(width: size, height: size)
        .background(Circle().fill(active ? Theme.textPrimary : Color.white.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(PressableStyle())
  }
}
