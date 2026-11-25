import AppKit
import DeltaveeCore
import Foundation

enum QuotaPresentation {
  enum UsageSeverity: Equatable {
    case normal, warning, critical
  }

  static func usageSeverity(usedPercent: Double?) -> UsageSeverity? {
    guard let usedPercent, usedPercent.isFinite else { return nil }
    if usedPercent >= 90 { return .critical }
    if usedPercent >= 70 { return .warning }
    return .normal
  }

  /// Legend thresholds in the user's percent mode; severity itself always follows actual usage.
  static func severityLegend(mode: PercentMode) -> [(label: String, severity: UsageSeverity)] {
    switch mode {
    case .used: [("<70%", .normal), ("70–<90%", .warning), ("≥90%", .critical)]
    case .remaining: [(">30%", .normal), (">10–30%", .warning), ("≤10%", .critical)]
    }
  }

  static func severityLegendAccessibilityLabel(mode: PercentMode) -> String {
    switch mode {
    case .used: "Teal under 70% used, orange from 70% to under 90%, red from 90%"
    case .remaining: "Teal above 30% remaining, orange above 10% through 30%, red at 10% or less"
    }
  }

  /// Shared by the panel graph and the optional menu bar tint so both surfaces stay in sync.
  static func usageColor(_ severity: UsageSeverity) -> NSColor {
    switch severity {
    case .normal: .systemTeal
    case .warning: .systemOrange
    case .critical: .systemRed
    }
  }

  static func clockText(
    _ date: Date, timeFormat: TimeFormat, locale: Locale = .autoupdatingCurrent
  ) -> String {
    let uses12Hour: Bool
    switch timeFormat {
    case .auto:
      uses12Hour = locale.hourCycle == .zeroToEleven || locale.hourCycle == .oneToTwelve
    case .hour12: uses12Hour = true
    case .hour24: uses12Hour = false
    }
    // Follow the Mac's hour preference in Auto while keeping UI text and AM/PM in English.
    let format: Date.FormatString
    if uses12Hour {
      format =
        "\(hour: .defaultDigits(clock: .twelveHour, hourCycle: .oneBased)):\(minute: .twoDigits) \(dayPeriod: .standard(.abbreviated))"
    } else {
      format =
        "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
    }
    return date.formatted(
      Date.VerbatimFormatStyle(
        format: format, locale: Locale(identifier: "en_US"), timeZone: .current, calendar: .current)
    )
  }

  private static func dateText(_ date: Date, compact: Bool, timeFormat: TimeFormat) -> String {
    let format: Date.FormatString =
      compact
      ? "\(month: .abbreviated) \(day: .defaultDigits)"
      : "\(month: .abbreviated) \(day: .defaultDigits), \(year: .defaultDigits)"
    let day = date.formatted(
      Date.VerbatimFormatStyle(
        format: format, locale: Locale(identifier: "en_US"), timeZone: .current, calendar: .current)
    )
    // The compact panel line uses a comma so the widest 12-hour pair fits without shrinking.
    return "\(day)\(compact ? "," : " at") \(clockText(date, timeFormat: timeFormat))"
  }

  static func compactUpdatedText(
    _ snapshot: QuotaSnapshot, mode: TimeDisplayMode, now: Date, timeFormat: TimeFormat
  ) -> String {
    if mode == .relative { return "Updated \(elapsed(since: snapshot.observedAt, now: now))" }
    let text =
      Calendar.current.isDate(snapshot.observedAt, inSameDayAs: now)
      ? clockText(snapshot.observedAt, timeFormat: timeFormat)
      : dateText(snapshot.observedAt, compact: true, timeFormat: timeFormat)
    return "Updated \(text)"
  }

  static func compactResetText(
    _ reset: Date, mode: TimeDisplayMode, now: Date, timeFormat: TimeFormat
  ) -> String {
    if mode == .absolute {
      return "Resets \(dateText(reset, compact: true, timeFormat: timeFormat))"
    }
    return countdown(reset, now: now, prefix: "Resets in ")
  }

  static func updatedText(
    _ snapshot: QuotaSnapshot, mode: TimeDisplayMode, now: Date, timeFormat: TimeFormat
  ) -> String {
    if mode == .relative { return "Updated \(elapsed(since: snapshot.observedAt, now: now))" }
    return "Updated \(dateText(snapshot.observedAt, compact: false, timeFormat: timeFormat))"
  }

  /// Floor-rounded age with at most two units, e.g. `5m ago`, `2h 5m ago`, `3d 4h ago`.
  /// Future capture times (clock skew) and ages under a minute read as `just now`.
  static func elapsed(since date: Date, now: Date) -> String {
    let seconds = now.timeIntervalSince(date)
    guard seconds.isFinite, seconds >= 60 else { return "just now" }
    let flooredMinutes = (seconds / 60).rounded(.down)
    guard flooredMinutes < Double(Int.max) else { return "just now" }
    let minutes = Int(flooredMinutes)
    let units = [(minutes / 1440, "d"), (minutes % 1440 / 60, "h"), (minutes % 60, "m")]
    guard let first = units.firstIndex(where: { $0.0 > 0 }) else { return "just now" }
    let parts = units[first...].prefix(2).filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
    return parts.joined(separator: " ") + " ago"
  }

  static func observationDetails(_ snapshot: QuotaSnapshot, timeFormat: TimeFormat) -> String {
    "Updated: \(dateText(snapshot.observedAt, compact: false, timeFormat: timeFormat))\nLast read: \(dateText(snapshot.fetchedAt, compact: false, timeFormat: timeFormat))\nSource: \(snapshot.source.rawValue)"
  }

  static func resetText(
    _ reset: Date, mode: TimeDisplayMode, now: Date, timeFormat: TimeFormat
  ) -> String {
    if mode == .absolute {
      return "Resets \(dateText(reset, compact: false, timeFormat: timeFormat))"
    }
    return countdown(reset, now: now, prefix: "Resets in ")
  }

  /// When collection resumes after a rate limit, following the reset-time display mode.
  /// Today's release shows only the clock time so the note stays one line at panel width.
  static func resumeText(
    _ release: Date, mode: TimeDisplayMode, now: Date, timeFormat: TimeFormat
  ) -> String {
    if mode == .relative {
      return release > now ? countdown(release, now: now, prefix: "Resumes in ") : "Resuming"
    }
    let text =
      Calendar.current.isDate(release, inSameDayAs: now)
      ? clockText(release, timeFormat: timeFormat)
      : dateText(release, compact: true, timeFormat: timeFormat)
    return "Resumes \(text)"
  }

  static func rateLimitText(
    _ release: Date, mode: TimeDisplayMode, now: Date, timeFormat: TimeFormat
  ) -> String {
    "Rate limited · \(resumeText(release, mode: mode, now: now, timeFormat: timeFormat))"
  }

  /// Panel line for banked resets, e.g. `3 resets · Use by Dec 1, 5:22 AM`. Nil when there are none.
  /// When only some of the resets restore the weekly quota, the line says how many do, as in
  /// `4 resets · 1 weekly · Use by …`. When the response listed fewer resets than it counted, the expiry
  /// is the earliest listed one and the line says how many were listed. Once that expiry passes, the
  /// count is only what the last read reported, so the line says so instead of calling the resets held.
  static func availableResetsText(
    _ resets: AvailableResets, mode: TimeDisplayMode, now: Date, timeFormat: TimeFormat
  ) -> String? {
    guard resets.count > 0 else { return nil }
    var parts = ["\(resets.count) \(resets.count == 1 ? "reset" : "resets")"]
    if let weekly = resets.weeklyCount, weekly != resets.count { parts.append("\(weekly) weekly") }
    guard let expiry = resets.earliestListedExpiry else {
      return parts.count == 1 ? "\(parts[0]) held" : parts.joined(separator: " · ")
    }
    guard expiry > now else { return "Last reported: \(resets.count) · Expiry passed" }
    // The expiry covers only the listed resets, so say how many those were.
    if let listed = resets.listedCount, !resets.listsAll { parts.append("\(listed) listed") }
    parts.append(
      mode == .absolute
        ? "Use by \(dateText(expiry, compact: true, timeFormat: timeFormat))"
        : countdown(expiry, now: now, prefix: "Expires in "))
    return parts.joined(separator: " · ")
  }

  /// Full description for the tooltip and VoiceOver. Nil when there are no resets.
  static func availableResetsDetails(
    _ resets: AvailableResets, now: Date, timeFormat: TimeFormat
  ) -> String? {
    guard resets.count > 0 else { return nil }
    let elapsed = resets.earliestListedExpiry.map { $0 <= now } ?? false
    let noun = "banked \(resets.count == 1 ? "reset" : "resets")"
    var text =
      elapsed
      ? "Last read reported \(resets.count) \(noun); refresh to see what remains."
      : "\(resets.count) \(noun) held."
    let partial = !resets.listsAll
    if let listed = resets.listedCount, partial { text += " \(listed) listed." }
    if let expiry = resets.earliestListedExpiry {
      let date = dateText(expiry, compact: false, timeFormat: timeFormat)
      text +=
        expiry > now
        ? " \(partial ? "Earliest listed expiry" : "Earliest expiry"): \(date)."
        : " \(partial ? "Earliest listed reset" : "Earliest reset") expired \(date)."
      if partial { text += " Unlisted resets may expire sooner." }
    }
    if let weekly = resets.weeklyCount, !elapsed {
      let others = resets.count - weekly
      func expiry(_ date: Date?) -> String {
        date.map { ", earliest expiry \(dateText($0, compact: false, timeFormat: timeFormat))." }
          ?? "."
      }
      if weekly == 0 {
        text += " None restores the weekly quota shown here."
      } else {
        text += " \(weekly) \(weekly == 1 ? "restores" : "restore") the weekly quota"
        text += expiry(resets.weeklyEarliestExpiry)
        if others > 0 {
          text += " \(others) \(others == 1 ? "restores" : "restore") other limits only"
          text += expiry(resets.otherEarliestExpiry)
        }
      }
    }
    return text
  }

  private static func countdown(_ reset: Date, now: Date, prefix: String) -> String {
    let seconds = reset.timeIntervalSince(now)
    guard seconds.isFinite else { return "Reset time unavailable" }
    guard seconds > 0 else { return "Reset time passed" }
    let roundedMinutes = ceil(seconds / 60)
    guard roundedMinutes < Double(Int.max) else { return "Reset time unavailable" }
    let minutes = Int(roundedMinutes)
    let days = minutes / 1440
    let hours = minutes % 1440 / 60
    let remainder = minutes % 60
    let parts = [
      days > 0 ? "\(days)d" : nil,
      hours > 0 ? "\(hours)h" : nil,
      remainder > 0 || minutes < 60 ? "\(remainder)m" : nil,
    ].compactMap { $0 }
    return prefix + parts.joined(separator: " ")
  }

  /// `email` is the account's detected email, used when the account has no label.
  static func accountAccessibilityLabel(_ account: Account, email: String?) -> String {
    let provider = account.provider.displayName
    return account.displayLabel(email: email).map { "\($0), \(provider)" } ?? provider
  }
}
