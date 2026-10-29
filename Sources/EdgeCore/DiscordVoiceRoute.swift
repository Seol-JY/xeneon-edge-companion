import Foundation

public struct DiscordVoiceDevice: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public init(id: String, name: String) { self.id = id; self.name = name }
}

/// A voice settings update may contain only a changed ID, leaving the device list untouched.
public struct DiscordVoiceRoute: Equatable, Sendable {
  public var selectedID: String?
  public var devices: [DiscordVoiceDevice]
  public init(selectedID: String? = nil, devices: [DiscordVoiceDevice] = []) {
    self.selectedID = selectedID; self.devices = devices
  }
  public var selected: DiscordVoiceDevice? { devices.first { $0.id == selectedID } }
  public func applying(_ data: [String: Any]) -> Self {
    var updated = self
    if data.keys.contains("device_id") {
      let id = data["device_id"] as? String
      updated.selectedID = id?.isEmpty == false ? id : nil
    }
    if let devices = data["available_devices"] as? [[String: Any]] {
      var seen = Set<String>()
      updated.devices = devices.compactMap {
        guard let id = $0["id"] as? String, !id.isEmpty,
              let name = $0["name"] as? String, !name.isEmpty, seen.insert(id).inserted else { return nil }
        return DiscordVoiceDevice(id: id, name: name)
      }
    }
    return updated
  }
}
