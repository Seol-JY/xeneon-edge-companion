import AppKit

// Writing to a child process that already exited (e.g. `codex app-server`) must not kill the app.
signal(SIGPIPE, SIG_IGN)

// Claude Code status line command: store the rate limits, print a summary, exit.
if CommandLine.arguments.contains(ClaudeStatusLine.flag) {
  ClaudeStatusLine.runCommand()
  exit(0)
}

// Diagnostic entry point (run from a terminal, no UI).
if CommandLine.arguments.contains("--telemetry-dump") {
  MainActor.assumeIsolated { TelemetryDebug.run() }
  exit(0)
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  withExtendedLifetime(delegate) { app.run() }
}
