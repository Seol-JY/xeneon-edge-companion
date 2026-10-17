import Foundation

/// The Discord desktop client's local RPC socket (`$TMPDIR/discord-ipc-N`). Each frame is a
/// little-endian opcode and length followed by JSON. Reads run on their own thread; messages and
/// the close are delivered on the main queue.
final class DiscordIPC {
  enum Op: UInt32 { case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4 }

  var onMessage: (([String: Any]) -> Void)?
  var onClose: ((String?) -> Void)?

  private var fd: Int32 = -1
  private let writeLock = NSLock()

  /// Connects to the first socket the client answers on and sends the handshake.
  func connect(clientID: String) -> Bool {
    close()
    let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    for n in 0 ..< 10 {
      let path = (dir as NSString).appendingPathComponent("discord-ipc-\(n)")
      guard FileManager.default.fileExists(atPath: path) else { continue }
      let s = socket(AF_UNIX, SOCK_STREAM, 0)
      guard s >= 0 else { continue }
      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
      withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
      }
      let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
      }
      guard ok else {
        Darwin.close(s)
        continue
      }
      var one: Int32 = 1
      setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      fd = s
      let reader = Thread { [weak self] in self?.readLoop(s) }
      reader.name = "discord-ipc"
      reader.start()
      send(.handshake, ["v": 1, "client_id": clientID])
      return true
    }
    return false
  }

  var isOpen: Bool { fd >= 0 }

  func close() {
    guard fd >= 0 else { return }
    let s = fd
    fd = -1
    shutdown(s, SHUT_RDWR)
    Darwin.close(s)
  }

  func send(_ op: Op, _ object: [String: Any]) {
    guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: object) else { return }
    var header = Data(count: 8)
    header.withUnsafeMutableBytes { raw in
      raw.storeBytes(of: op.rawValue.littleEndian, toByteOffset: 0, as: UInt32.self)
      raw.storeBytes(of: UInt32(body.count).littleEndian, toByteOffset: 4, as: UInt32.self)
    }
    let packet = header + body
    writeLock.lock()
    defer { writeLock.unlock() }
    packet.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
        if n <= 0 { break }
        sent += n
      }
    }
  }

  private func readLoop(_ s: Int32) {
    var reason: String?
    while true {
      guard let header = readExactly(s, 8) else { break }
      let op = header.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: 0, as: UInt32.self)) }
      let length = header.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: 4, as: UInt32.self)) }
      guard length < 4 << 20, let body = readExactly(s, Int(length)) else { break }
      let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
      switch Op(rawValue: op) {
      case .ping:
        send(.pong, object)
      case .close:
        reason = object["message"] as? String
      case .frame:
        DispatchQueue.main.async { [weak self] in self?.onMessage?(object) }
      default:
        break
      }
      if Op(rawValue: op) == .close { break }
    }
    DispatchQueue.main.async { [weak self] in
      // Only a socket that dropped by itself is reported; one we closed (or replaced) is not.
      guard let self, self.fd == s else { return }
      self.close()
      self.onClose?(reason)
    }
  }

  private func readExactly(_ s: Int32, _ count: Int) -> Data? {
    var data = Data(count: count)
    var got = 0
    while got < count {
      let n = data.withUnsafeMutableBytes { read(s, $0.baseAddress! + got, count - got) }
      if n <= 0 { return nil }
      got += n
    }
    return data
  }
}

/// Discord secrets in the login keychain: the client secret the user pastes in and the OAuth tokens.
enum DiscordKeychain {
  private static let service = "pro.seol.EdgeCompanion.discord"

  static func get(_ account: String) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func set(_ value: String?, for account: String) {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    SecItemDelete(query as CFDictionary)
    guard let value, !value.isEmpty else { return }
    var add = query
    add[kSecValueData] = Data(value.utf8)
    SecItemAdd(add as CFDictionary, nil)
  }
}
