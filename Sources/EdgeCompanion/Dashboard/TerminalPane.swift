import AppKit
import SwiftTerm
import SwiftUI

/// Terminal view that takes keyboard focus when touched on the Edge.
final class EdgeTerminalView: LocalProcessTerminalView, KeyboardFocusable {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the terminal process so it survives SwiftUI view rebuilds and dashboard hide/show.
/// Wraps the shell in a tmux session when available, so work keeps running across app restarts and
/// the same session can be attached from any other terminal with `tmux -L edge attach -t edge`.
/// It uses its own tmux server (`-L edge`) and config, leaving the user's tmux setup untouched.
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
  static let shared = TerminalSession()
  static let tmuxSessionName = "edge"
  static let tmuxSocketName = "edge"
  static var attachCommand: String { "tmux -L \(tmuxSocketName) attach -t \(tmuxSessionName)" }

  @Published private(set) var isRunning = false
  @Published private(set) var title = "Terminal"

  let view: EdgeTerminalView
  private var fontSize: CGFloat = 14
  private var useTmux = true

  override init() {
    view = EdgeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    super.init()
    view.processDelegate = self
    view.nativeBackgroundColor = NSColor(red: 0.075, green: 0.083, blue: 0.102, alpha: 1)
    view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
    view.caretColor = NSColor(red: 0.20, green: 0.82, blue: 0.75, alpha: 1)
    view.optionAsMetaKey = true
    view.font = Self.terminalFont(size: fontSize)
  }

  /// JetBrains Mono Nerd Font Mono, bundled in the app (Resources/Fonts, registered through
  /// ATSApplicationFontsPath); its icons keep prompt themes one cell wide. It has no Hangul, so
  /// Korean falls back to the system Gothic. SF Mono covers runs outside the app bundle.
  static func terminalFont(size: CGFloat) -> NSFont {
    NSFont(name: "JetBrainsMonoNFM-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
  }

  func configure(fontSize: CGFloat, useTmux: Bool) {
    if fontSize != self.fontSize {
      self.fontSize = fontSize
      view.font = Self.terminalFont(size: fontSize)
    }
    self.useTmux = useTmux
  }

  func startIfNeeded() {
    guard !isRunning else { return }
    var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
    if !env.contains(where: { $0.hasPrefix("LANG=") }) { env.append("LANG=en_US.UTF-8") }
    env.append("EDGE_COMPANION=1")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    if useTmux, let tmux = Self.findTmux(), let config = Self.writeTmuxConfig() {
      let args = ["-L", Self.tmuxSocketName, "-f", config.path, "new-session", "-A", "-s", Self.tmuxSessionName]
      view.startProcess(executable: tmux, args: args, environment: env + ["SHELL=\(shell)"], execName: "tmux", currentDirectory: home)
      Log.info(.dashboard, "terminal started (tmux -L \(Self.tmuxSocketName), session '\(Self.tmuxSessionName)')")
    } else {
      // A leading dash makes the shell a login shell, like Terminal.app.
      let name = "-" + (shell as NSString).lastPathComponent
      view.startProcess(executable: shell, args: [], environment: env, execName: name, currentDirectory: home)
      Log.info(.dashboard, "terminal started (\(shell))")
    }
    isRunning = true
    let url = CTFontCopyAttribute(view.font as CTFont, kCTFontURLAttribute) as? URL
    Log.info(.dashboard, "terminal font \(view.font.fontName) from \(url?.path ?? "?")")
  }

  func restart() {
    isRunning = false
    view.feed(text: "\u{1b}c")
    startIfNeeded()
  }

  /// The dashboard's tmux config: the user's own ~/.tmux.conf first, then what touch needs.
  /// `mouse on` turns finger and trackpad scrolling into scrollback instead of shell history.
  static func writeTmuxConfig() -> URL? {
    let fm = FileManager.default
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let dir = support.appendingPathComponent("EdgeCompanion", isDirectory: true)
    let url = dir.appendingPathComponent("tmux.conf")
    let config = """
    # Written by EdgeCompanion for the Edge dashboard terminal (tmux -L edge). Rewritten on launch.
    if-shell "test -f ~/.tmux.conf" "source-file ~/.tmux.conf"
    set -g mouse on
    set -g default-terminal "tmux-256color"
    set -ga terminal-overrides ",xterm-256color:Tc"
    set -g history-limit 50000
    set -g set-clipboard on
    set -sg escape-time 10
    set -g status-style "bg=default,fg=colour244"
    set -g status-left ""
    set -g status-right "#{session_name}"
    """
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      try config.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      Log.error(.dashboard, "cannot write tmux config: \(error.localizedDescription)")
      return nil
    }
  }

  static func findTmux() -> String? {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  // MARK: LocalProcessTerminalViewDelegate

  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    DispatchQueue.main.async { self.title = title.isEmpty ? "Terminal" : title }
  }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func processTerminated(source: TerminalView, exitCode: Int32?) {
    DispatchQueue.main.async {
      self.isRunning = false
      Log.info(.dashboard, "terminal process exited (\(exitCode.map(String.init) ?? "?"))")
    }
  }
}

struct TerminalPane: NSViewRepresentable {
  @ObservedObject var session: TerminalSession

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    let term = session.view
    term.removeFromSuperview()
    term.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(term)
    NSLayoutConstraint.activate([
      term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      term.topAnchor.constraint(equalTo: container.topAnchor),
      term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    session.startIfNeeded()
    return container
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TerminalCard: View {
  @ObservedObject var session: TerminalSession

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Circle().fill(session.isRunning ? Theme.cpu : Theme.textTertiary).frame(width: 8, height: 8)
        Text(session.title)
          .font(Theme.text(12, weight: .semibold))
          .foregroundStyle(Theme.textSecondary)
          .lineLimit(1)
        Spacer()
        if !session.isRunning {
          Button("Restart") { session.restart() }
            .buttonStyle(.plain)
            .font(Theme.text(12, weight: .semibold))
            .foregroundStyle(Theme.cpu)
        }
      }
      .padding(.horizontal, 16)
      .frame(height: 34)
      TerminalPane(session: session)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
    .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.card))
    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
  }
}
