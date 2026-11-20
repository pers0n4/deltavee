import Foundation

public enum PercentMode: String, Codable, Sendable, CaseIterable { case used, remaining }
public enum TimeDisplayMode: String, Codable, Sendable, CaseIterable { case absolute, relative }
public enum TimeFormat: String, Codable, Sendable, CaseIterable { case auto, hour12, hour24 }
/// Panel appearance; `system` follows the macOS appearance.
public enum AppTheme: String, Codable, Sendable, CaseIterable { case system, light, dark }
public enum ClaudeSource: String, Codable, Sendable, CaseIterable {
  case oauthWithStatusline, statuslineOnly
}
public struct Settings: Codable, Sendable, Equatable {
  public var mode: PercentMode = .remaining
  public var resetTimeMode: TimeDisplayMode = .absolute
  public var updatedTimeMode: TimeDisplayMode = .absolute
  public var timeFormat: TimeFormat = .auto
  public var claudeSource: ClaudeSource = .oauthWithStatusline
  public var intervalSeconds: Double = 600
  public var claudePath: String = ""
  public var codexPath: String = ""
  /// Tints the menu bar percentages with the weekly graph's severity colors.
  public var colorMenuBarUsage: Bool = false
  /// Keeps the panel's translucent popover material; `false` draws an opaque window background.
  public var transparentPanel: Bool = true
  /// Panel and settings appearance. The menu bar text keeps following the menu bar itself.
  public var theme: AppTheme = .system
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case mode, resetTimeMode, updatedTimeMode, timeFormat, claudeSource, intervalSeconds, codexPath
    case claudePath
    case colorMenuBarUsage, transparentPanel, theme
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decode(PercentMode.self, forKey: .mode)
    claudeSource = try container.decode(ClaudeSource.self, forKey: .claudeSource)
    // Free-form intervals saved before the fixed choices snap to the nearest choice.
    intervalSeconds = Self.nearestInterval(
      to: try container.decode(Double.self, forKey: .intervalSeconds))
    codexPath = try container.decode(String.self, forKey: .codexPath)
    claudePath = try container.decodeIfPresent(String.self, forKey: .claudePath) ?? ""
    // Documents saved before the reset-time preference have no value for this key.
    resetTimeMode =
      try container.decodeIfPresent(TimeDisplayMode.self, forKey: .resetTimeMode) ?? .absolute
    // The update-time preference was added after existing account documents were saved.
    updatedTimeMode =
      try container.decodeIfPresent(TimeDisplayMode.self, forKey: .updatedTimeMode) ?? .absolute
    // The clock-format preference was added after existing account documents were saved.
    timeFormat = try container.decodeIfPresent(TimeFormat.self, forKey: .timeFormat) ?? .auto
    // Appearance preferences were added after existing account documents were saved.
    colorMenuBarUsage =
      try container.decodeIfPresent(Bool.self, forKey: .colorMenuBarUsage) ?? false
    transparentPanel = try container.decodeIfPresent(Bool.self, forKey: .transparentPanel) ?? true
    theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
  }
  /// Refresh interval choices in seconds. All stay under `QuotaSnapshot.staleAfter`, and the
  /// longest equals the failure backoff cap.
  public static let intervalChoices: [Double] = [180, 300, 600, 900, 1800]
  /// The closest choice; a tie takes the longer interval, and a non-finite value the default.
  public static func nearestInterval(to seconds: Double) -> Double {
    guard seconds.isFinite else { return Settings().intervalSeconds }
    return intervalChoices.min { lhs, rhs in
      let (left, right) = (abs(lhs - seconds), abs(rhs - seconds))
      return left == right ? lhs > rhs : left < right
    }!
  }
  public var validInterval: Double { Self.nearestInterval(to: intervalSeconds) }
}
