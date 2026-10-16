import CoreGraphics
import Darwin
import Foundation

/// Hides the cursor briefly while the app moves it on the user's behalf (Dock relocation).
///
/// A background app's hide request is ignored unless its WindowServer connection sets the private
/// "SetsCursorInBackground" property (as xeneon-toolbox does). The symbols are looked up at runtime;
/// if they are missing the cursor simply stays visible.
enum CursorHider {
  private typealias DefaultConnection = @convention(c) () -> Int32
  private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

  private static let enabled: Bool = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let connSym = dlsym(handle, "_CGSDefaultConnection"),
          let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return false }
    let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
    let set = unsafeBitCast(setSym, to: SetProperty.self)
    return set(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
  }()

  /// Runs `body` with the cursor hidden, keeping hide/show balanced.
  static func whileHidden(_ body: () -> Void) {
    let hidden = enabled && CGDisplayHideCursor(CGMainDisplayID()) == .success
    defer { if hidden { CGDisplayShowCursor(CGMainDisplayID()) } }
    body()
  }
}
