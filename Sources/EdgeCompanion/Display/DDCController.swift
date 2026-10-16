import EdgeCore
import Foundation
import IOKit

// Private IOKit entry points used by MonitorControl, Lunar and m1ddc for DDC on Apple Silicon.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32, _ buffer: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ buffer: UnsafeMutableRawPointer, _ length: UInt32) -> IOReturn

/// DDC/CI access to the Edge, restricted to the colour VCP codes in `EdgeVCP`.
/// All I/O runs on one serial queue; the bus is slow (tens of ms per transaction) and shared
/// with MonitorControl, so we keep transactions short and spaced.
final class DDCController {
  enum DDCError: Error, CustomStringConvertible {
    case noService
    case noReply(UInt8)
    case unsupported(UInt8)

    var description: String {
      switch self {
      case .noService: return "Edge DDC service not found"
      case let .noReply(v): return String(format: "no reply for VCP 0x%02X", v)
      case let .unsupported(v): return String(format: "VCP 0x%02X unsupported", v)
      }
    }
  }

  let queue = DispatchQueue(label: "pro.seol.EdgeCompanion.ddc", qos: .utility)
  private var service: CFTypeRef?

  /// Drops the cached service; call when the Edge disconnects.
  func invalidate() {
    queue.async { self.service = nil }
  }

  // MARK: Queue-confined API (call only from `queue`)

  func read(_ vcp: EdgeVCP) throws -> DDCPacket.VCPReply {
    let svc = try resolveService()
    var request = DDCPacket.getVCP(vcp.rawValue)
    for attempt in 0 ..< 5 {
      usleep(10000)
      _ = IOAVServiceWriteI2C(svc, UInt32(DDCPacket.chipAddress), UInt32(DDCPacket.dataAddress), &request, UInt32(request.count))
      usleep(50000)
      var reply = [UInt8](repeating: 0, count: 11)
      if IOAVServiceReadI2C(svc, UInt32(DDCPacket.chipAddress), 0, &reply, UInt32(reply.count)) == kIOReturnSuccess {
        switch DDCPacket.parseReply(reply, expecting: vcp.rawValue) {
        case let .success(r): return r
        case let .failure(.unsupported(code)) where attempt >= 1:
          _ = code
          throw DDCError.unsupported(vcp.rawValue)
        case .failure: break
        }
      }
      usleep(30000)
    }
    throw DDCError.noReply(vcp.rawValue)
  }

  func write(_ vcp: EdgeVCP, _ value: UInt16) throws {
    let svc = try resolveService()
    var packet = DDCPacket.setVCP(vcp.rawValue, value: value)
    // Sent twice, 10 ms apart, as MonitorControl does; some scalers drop the first frame.
    var ok = false
    for _ in 0 ..< 2 {
      usleep(10000)
      ok = IOAVServiceWriteI2C(svc, UInt32(DDCPacket.chipAddress), UInt32(DDCPacket.dataAddress), &packet, UInt32(packet.count)) == kIOReturnSuccess || ok
    }
    if !ok { throw DDCError.noReply(vcp.rawValue) }
    // Give the scaler time to commit before the next transaction.
    usleep(60000)
  }

  private func resolveService() throws -> CFTypeRef {
    if let service { return service }
    let framebuffers = IORegistryDisplays.edgeFramebuffers()
    defer { framebuffers.forEach { IOObjectRelease($0.avServiceEntry) } }
    guard let fb = framebuffers.first,
          let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, fb.avServiceEntry)?.takeRetainedValue() else {
      throw DDCError.noService
    }
    service = svc
    return svc
  }
}
