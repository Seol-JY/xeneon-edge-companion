import Foundation

/// UI language for the menu and settings window (the dashboard widgets are not localized).
enum AppLanguage: String, Codable, CaseIterable {
  case system, en, ko

  /// The language actually used, resolving `.system` from the user's preferred languages.
  var resolved: AppLanguage {
    guard self == .system else { return self }
    let preferred = Locale.preferredLanguages.first ?? "en"
    return preferred.hasPrefix("ko") ? .ko : .en
  }
}

/// Picks the Korean or English string for the current UI language. Both texts sit side by side at
/// the call site so a translation is always next to its original.
func tr(_ ko: String, _ en: String) -> String {
  SettingsStore.shared.settings.language.resolved == .ko ? ko : en
}
