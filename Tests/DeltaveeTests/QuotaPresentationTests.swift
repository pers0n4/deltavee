import DeltaveeCore
import Foundation
import XCTest

@testable import Deltavee

final class QuotaPresentationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_900_000_000)

  private func localDate(year: Int = 2030, month: Int = 11, day: Int = 12, hour: Int, minute: Int)
    throws -> Date
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: year, month: month, day: day, hour: hour, minute: minute)))
  }

  func testAutoClockFollowsLocaleHourCycleAndExplicitChoicesOverrideIt() throws {
    let cases = [
      (0, 5, "12:05 AM", "00:05"),
      (12, 0, "12:00 PM", "12:00"),
      (23, 7, "11:07 PM", "23:07"),
    ]
    for (identifier, uses12Hour) in [
      ("en_US", true), ("en_GB", false), ("en_US@hours=h23", false),
      ("en_GB@hours=h12", true), ("en_US@hours=h11", true), ("en_US@hours=h24", false),
    ] {
      let locale = Locale(identifier: identifier)
      for (hour, minute, hour12, hour24) in cases {
        let date = try localDate(hour: hour, minute: minute)
        XCTAssertEqual(
          QuotaPresentation.clockText(date, timeFormat: .auto, locale: locale),
          uses12Hour ? hour12 : hour24, identifier)
        XCTAssertEqual(
          QuotaPresentation.clockText(date, timeFormat: .hour12, locale: locale), hour12, identifier
        )
        XCTAssertEqual(
          QuotaPresentation.clockText(date, timeFormat: .hour24, locale: locale), hour24, identifier
        )
      }
    }
  }

  func testAutoClockUsesMacPreferenceAcrossAbsoluteTimeSurfaces() throws {
    let date = try localDate(hour: 23, minute: 7)
    let snapshot = QuotaSnapshot(
      weeklyUsedPercent: 42, observedAt: date, fetchedAt: date, source: .claudeStatusline)
    let pattern = try XCTUnwrap(
      DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent))
    let clock = pattern.contains("a") ? "11:07 PM" : "23:07"
    XCTAssertEqual(
      QuotaPresentation.compactUpdatedText(snapshot, mode: .absolute, now: date, timeFormat: .auto),
      "Updated \(clock)")
    XCTAssertEqual(
      QuotaPresentation.updatedText(snapshot, mode: .absolute, now: date, timeFormat: .auto),
      "Updated Nov 12, 2030 at \(clock)")
    XCTAssertEqual(
      QuotaPresentation.compactResetText(date, mode: .absolute, now: date, timeFormat: .auto),
      "Resets Nov 12, \(clock)")
    XCTAssertEqual(
      QuotaPresentation.resetText(date, mode: .absolute, now: date, timeFormat: .auto),
      "Resets Nov 12, 2030 at \(clock)")
    XCTAssertEqual(
      QuotaPresentation.rateLimitText(date, mode: .absolute, now: date, timeFormat: .auto),
      "Rate limited · Resumes \(clock)")
    XCTAssertEqual(
      QuotaPresentation.observationDetails(snapshot, timeFormat: .auto),
      "Updated: Nov 12, 2030 at \(clock)\nLast read: Nov 12, 2030 at \(clock)\nSource: claudeStatusline"
    )
  }

  func testExplicitClockFormatsAtMidnightNoonAndEvening() throws {
    let cases = [
      (0, 5, "12:05 AM", "00:05"),
      (12, 0, "12:00 PM", "12:00"),
      (23, 7, "11:07 PM", "23:07"),
    ]
    for (hour, minute, hour12, hour24) in cases {
      let date = try localDate(hour: hour, minute: minute)
      let snapshot = QuotaSnapshot(
        weeklyUsedPercent: 42, observedAt: date, fetchedAt: date, source: .claudeStatusline)
      for (format, clock) in [(TimeFormat.hour12, hour12), (.hour24, hour24)] {
        XCTAssertEqual(
          QuotaPresentation.compactUpdatedText(
            snapshot, mode: .absolute, now: date, timeFormat: format),
          "Updated \(clock)")
        XCTAssertEqual(
          QuotaPresentation.compactUpdatedText(
            snapshot, mode: .absolute, now: date.addingTimeInterval(172800), timeFormat: format),
          "Updated Nov 12, \(clock)")
        XCTAssertEqual(
          QuotaPresentation.updatedText(snapshot, mode: .absolute, now: now, timeFormat: format),
          "Updated Nov 12, 2030 at \(clock)")
        XCTAssertEqual(
          QuotaPresentation.compactResetText(date, mode: .absolute, now: now, timeFormat: format),
          "Resets Nov 12, \(clock)")
        XCTAssertEqual(
          QuotaPresentation.resetText(date, mode: .absolute, now: now, timeFormat: format),
          "Resets Nov 12, 2030 at \(clock)")
      }
    }
  }

  func testRateLimitTextShowsResumeTimeInEachDisplayMode() throws {
    let release = try localDate(hour: 23, minute: 7)
    let morning = try localDate(hour: 9, minute: 0)
    XCTAssertEqual(
      QuotaPresentation.rateLimitText(release, mode: .absolute, now: morning, timeFormat: .hour24),
      "Rate limited · Resumes 23:07")
    XCTAssertEqual(
      QuotaPresentation.rateLimitText(
        release, mode: .absolute, now: morning.addingTimeInterval(-86400), timeFormat: .hour12),
      "Rate limited · Resumes Nov 12, 11:07 PM")
    XCTAssertEqual(
      QuotaPresentation.rateLimitText(
        release, mode: .relative, now: release.addingTimeInterval(-1500), timeFormat: .hour12),
      "Rate limited · Resumes in 25m")
    XCTAssertEqual(
      QuotaPresentation.rateLimitText(release, mode: .relative, now: release, timeFormat: .hour12),
      "Rate limited · Resuming")
  }

  func testTooltipKeepsUpdatedAndReadDatesAndSourceInBothClockFormats() throws {
    let captured = try localDate(year: 2030, month: 12, day: 31, hour: 23, minute: 7)
    let read = try localDate(year: 2031, month: 1, day: 1, hour: 0, minute: 5)
    for source in [UsageSource.claudeStatusline, .claudeOAuth, .codexAppServer] {
      let snapshot = QuotaSnapshot(
        weeklyUsedPercent: 42, observedAt: captured, fetchedAt: read, source: source)
      for (format, capturedClock, readClock) in [
        (TimeFormat.hour12, "11:07 PM", "12:05 AM"), (.hour24, "23:07", "00:05"),
      ] {
        XCTAssertEqual(
          QuotaPresentation.observationDetails(snapshot, timeFormat: format),
          "Updated: Dec 31, 2030 at \(capturedClock)\nLast read: Jan 1, 2031 at \(readClock)\nSource: \(source.rawValue)"
        )
        XCTAssertEqual(
          QuotaPresentation.compactUpdatedText(
            snapshot, mode: .absolute, now: read, timeFormat: format),
          "Updated Dec 31, \(capturedClock)")
        XCTAssertEqual(
          QuotaPresentation.updatedText(snapshot, mode: .absolute, now: now, timeFormat: format),
          "Updated Dec 31, 2030 at \(capturedClock)")
      }
    }
  }

  func testClockPreferenceDoesNotChangeRelativeResetSemantics() {
    let cases: [(TimeInterval, String)] = [
      (-1, "Reset time passed"), (0, "Reset time passed"), (1, "Resets in 1m"),
      (61, "Resets in 2m"), (7500, "Resets in 2h 5m"), (104580, "Resets in 1d 5h 3m"),
      (.infinity, "Reset time unavailable"), (.nan, "Reset time unavailable"),
      (1e300, "Reset time unavailable"),
    ]
    for format in TimeFormat.allCases {
      for (seconds, expected) in cases {
        let reset = now.addingTimeInterval(seconds)
        XCTAssertEqual(
          QuotaPresentation.compactResetText(reset, mode: .relative, now: now, timeFormat: format),
          expected)
        XCTAssertEqual(
          QuotaPresentation.resetText(reset, mode: .relative, now: now, timeFormat: format),
          expected)
      }
    }
  }

  func testUsageSeverityUsesConsumedQuotaBoundaries() {
    let cases: [(Double, QuotaPresentation.UsageSeverity)] = [
      (0, .normal), (69.99, .normal), (70, .warning),
      (89.99, .warning), (90, .critical), (100, .critical),
    ]
    for (used, expected) in cases {
      XCTAssertEqual(QuotaPresentation.usageSeverity(usedPercent: used), expected, "Used: \(used)")
    }
  }

  func testSeverityLegendLabelsFollowPercentModeAtSameBoundaries() {
    XCTAssertEqual(
      QuotaPresentation.severityLegend(mode: .used).map(\.label), ["<70%", "70–<90%", "≥90%"])
    XCTAssertEqual(
      QuotaPresentation.severityLegend(mode: .remaining).map(\.label), [">30%", ">10–30%", "≤10%"])
    for mode in [PercentMode.used, .remaining] {
      XCTAssertEqual(
        QuotaPresentation.severityLegend(mode: mode).map(\.severity),
        [.normal, .warning, .critical])
    }
    // Remaining labels are inclusive exactly where used-percent severity changes.
    let cases: [(Double, QuotaPresentation.UsageSeverity)] = [
      (30.01, .normal), (30, .warning), (10.01, .warning), (10, .critical),
    ]
    for (remaining, expected) in cases {
      XCTAssertEqual(QuotaPresentation.usageSeverity(usedPercent: 100 - remaining), expected)
    }
    XCTAssertTrue(
      QuotaPresentation.severityLegendAccessibilityLabel(mode: .remaining).contains("remaining"))
  }

  func testUnavailableUsageHasNoSeverity() {
    let values: [Double?] = [nil, .nan, .infinity, -.infinity]
    for used in values {
      XCTAssertNil(QuotaPresentation.usageSeverity(usedPercent: used))
    }
  }

  func testRemainingDisplayDoesNotInvertConsumedQuotaSeverity() {
    let cases: [(Double, String, String, QuotaPresentation.UsageSeverity)] = [
      (10, "10%", "90%", .normal), (90, "90%", "10%", .critical),
    ]
    for (used, usedText, remainingText, severity) in cases {
      let snapshot = QuotaSnapshot(
        weeklyUsedPercent: used, observedAt: now, fetchedAt: now, source: .claudeStatusline)
      for (mode, expectedText) in [(PercentMode.used, usedText), (.remaining, remainingText)] {
        XCTAssertEqual(
          IconRenderer.percentage(snapshot.weeklyUsedPercent, mode: mode), expectedText)
        XCTAssertEqual(
          QuotaPresentation.usageSeverity(usedPercent: snapshot.weeklyUsedPercent), severity)
      }
    }
  }

  func testResetCountdownRoundsUpAndIncludesDaysHoursAndMinutes() {
    let cases: [(TimeInterval, String)] = [
      (1, "Resets in 1m"), (59, "Resets in 1m"), (60, "Resets in 1m"),
      (61, "Resets in 2m"), (3600, "Resets in 1h"),
      (7500, "Resets in 2h 5m"), (86400, "Resets in 1d"),
      (104580, "Resets in 1d 5h 3m"),
    ]
    for (seconds, expected) in cases {
      XCTAssertEqual(
        QuotaPresentation.resetText(
          now.addingTimeInterval(seconds), mode: .relative, now: now, timeFormat: .hour12),
        expected)
    }
  }

  func testElapsedResetDoesNotAssertThatQuotaWasRefreshed() {
    for seconds in [-3600.0, 0] {
      XCTAssertEqual(
        QuotaPresentation.resetText(
          now.addingTimeInterval(seconds), mode: .relative, now: now, timeFormat: .hour12),
        "Reset time passed")
    }
  }

  func testAbsoluteResetStaysFixedWhileCountdownChanges() {
    let reset = now.addingTimeInterval(7200)
    let absolute = QuotaPresentation.resetText(
      reset, mode: .absolute, now: now, timeFormat: .hour12)
    XCTAssertTrue(absolute.hasPrefix("Resets "))
    XCTAssertFalse(absolute.hasPrefix("Resets in "))
    XCTAssertEqual(
      absolute,
      QuotaPresentation.resetText(
        reset, mode: .absolute, now: now.addingTimeInterval(3600), timeFormat: .hour12))
    XCTAssertEqual(
      QuotaPresentation.resetText(reset, mode: .relative, now: now, timeFormat: .hour12),
      "Resets in 2h")
    XCTAssertEqual(
      QuotaPresentation.resetText(
        reset, mode: .relative, now: now.addingTimeInterval(3600), timeFormat: .hour12),
      "Resets in 1h")
  }

  func testUnrepresentableCountdownDoesNotOverflow() {
    for seconds in [Double.infinity, Double.nan, 1e300] {
      XCTAssertEqual(
        QuotaPresentation.resetText(
          Date(timeIntervalSince1970: seconds), mode: .relative, now: now, timeFormat: .hour12),
        "Reset time unavailable"
      )
    }
  }

  func testUpdatedTimeUsesObservationNotCacheReadTime() {
    let first = QuotaSnapshot(
      weeklyUsedPercent: 42, observedAt: now, fetchedAt: now.addingTimeInterval(600),
      source: .claudeStatusline)
    let reread = QuotaSnapshot(
      weeklyUsedPercent: 42, observedAt: now, fetchedAt: now.addingTimeInterval(1800),
      source: .claudeStatusline)
    XCTAssertEqual(
      QuotaPresentation.updatedText(first, mode: .absolute, now: now, timeFormat: .hour12),
      QuotaPresentation.updatedText(reread, mode: .absolute, now: now, timeFormat: .hour12))
    XCTAssertTrue(
      QuotaPresentation.updatedText(first, mode: .absolute, now: now, timeFormat: .hour12)
        .hasPrefix("Updated "))
    XCTAssertNotEqual(
      QuotaPresentation.observationDetails(first, timeFormat: .hour12),
      QuotaPresentation.observationDetails(reread, timeFormat: .hour12))
    let newer = QuotaSnapshot(
      weeklyUsedPercent: 43, observedAt: now.addingTimeInterval(3600),
      fetchedAt: now.addingTimeInterval(3600), source: .claudeStatusline)
    XCTAssertNotEqual(
      QuotaPresentation.updatedText(first, mode: .absolute, now: now, timeFormat: .hour12),
      QuotaPresentation.updatedText(newer, mode: .absolute, now: now, timeFormat: .hour12))
  }

  func testRelativeUpdatedTimeFloorsAgeToTwoUnits() {
    let cases: [(TimeInterval, String)] = [
      (-120, "just now"), (0, "just now"), (59, "just now"), (60, "1m ago"),
      (119, "1m ago"), (3599, "59m ago"), (3600, "1h ago"), (7500, "2h 5m ago"),
      (86399, "23h 59m ago"), (86400, "1d ago"), (90060, "1d 1h ago"),
      (86400 + 59 * 60, "1d ago"), (10 * 86400 + 7200 + 300, "10d 2h ago"),
    ]
    for (age, expected) in cases {
      let observed = now.addingTimeInterval(-age)
      let snapshot = QuotaSnapshot(
        weeklyUsedPercent: 42, observedAt: observed, fetchedAt: now, source: .claudeStatusline)
      for format in TimeFormat.allCases {
        XCTAssertEqual(
          QuotaPresentation.compactUpdatedText(
            snapshot, mode: .relative, now: now, timeFormat: format),
          "Updated \(expected)", "Age: \(age)")
        XCTAssertEqual(
          QuotaPresentation.updatedText(snapshot, mode: .relative, now: now, timeFormat: format),
          "Updated \(expected)")
      }
    }
    // The tooltip keeps exact capture and read times regardless of the display mode.
    let snapshot = QuotaSnapshot(
      weeklyUsedPercent: 42, observedAt: now.addingTimeInterval(-7500), fetchedAt: now,
      source: .claudeStatusline)
    XCTAssertTrue(
      QuotaPresentation.observationDetails(snapshot, timeFormat: .hour24).hasPrefix("Updated: "))
  }

  func testAccountAccessibilityNameDoesNotDuplicateProvider() {
    for (name, provider) in [
      ("Claude", Provider.anthropic), ("claude", .anthropic), ("Codex", .openai),
    ] {
      XCTAssertEqual(
        QuotaPresentation.accountAccessibilityLabel(
          Account(name: name, provider: provider, configDir: "/fake"), email: nil),
        provider.displayName)
    }
    XCTAssertEqual(
      QuotaPresentation.accountAccessibilityLabel(
        Account(name: "Work", provider: .openai, configDir: "/fake"), email: nil), "Work, Codex")
  }

  func testCompactResetPreservesCountdownAndFullTooltipDetail() {
    let reset = now.addingTimeInterval(7500)
    XCTAssertEqual(
      QuotaPresentation.compactResetText(reset, mode: .relative, now: now, timeFormat: .hour12),
      "Resets in 2h 5m")
    XCTAssertEqual(
      QuotaPresentation.compactResetText(now, mode: .relative, now: now, timeFormat: .hour12),
      "Reset time passed")
    let compact = QuotaPresentation.compactResetText(
      reset, mode: .absolute, now: now, timeFormat: .hour12)
    let full = QuotaPresentation.resetText(reset, mode: .absolute, now: now, timeFormat: .hour12)
    XCTAssertTrue(compact.hasPrefix("Resets "))
    XCTAssertLessThan(compact.count, full.count)
  }

  func testOptionalAccountLabelKeepsFixedProviderTitleAndMenuBarFallback() {
    for provider in Provider.allCases {
      for name in ["", " \n\t", provider.displayName, provider.displayName.lowercased()] {
        let account = Account(name: name, provider: provider, configDir: "/fake")
        XCTAssertNil(account.displayLabel)
        XCTAssertEqual(
          QuotaPresentation.accountAccessibilityLabel(account, email: nil), provider.displayName)
        // Without a label the detected email stands in everywhere the label would appear.
        let email = "fake@example.com"
        XCTAssertEqual(
          QuotaPresentation.accountAccessibilityLabel(account, email: email),
          "\(email), \(provider.displayName)")
        XCTAssertEqual(
          IconRenderer.parts(
            accounts: [account], states: [:], mode: .used, now: now, emails: [account.id: email]
          ).first?.accountName, email)
        XCTAssertEqual(
          IconRenderer.parts(accounts: [account], states: [:], mode: .used, now: now).first?
            .accountName, provider.displayName)
      }
      let account = Account(name: "  Work 계정  ", provider: provider, configDir: "/fake")
      XCTAssertEqual(account.displayLabel, "Work 계정")
      XCTAssertEqual(
        QuotaPresentation.accountAccessibilityLabel(account, email: "fake@example.com"),
        "Work 계정, \(provider.displayName)", "The user's label wins over the email")
      XCTAssertEqual(account.name, "  Work 계정  ")
      XCTAssertEqual(
        IconRenderer.parts(
          accounts: [account], states: [:], mode: .used, now: now,
          emails: [account.id: "fake@example.com"]
        ).first?.accountName, "Work 계정")
    }
  }

  func testCompactUpdatedKeepsOldObservationAndDistinguishesPriorDate() {
    let snapshot = QuotaSnapshot(
      weeklyUsedPercent: 42, observedAt: now, fetchedAt: now.addingTimeInterval(600),
      source: .claudeStatusline)
    let sameDay = QuotaPresentation.compactUpdatedText(
      snapshot, mode: .absolute, now: now, timeFormat: .hour12)
    XCTAssertEqual(
      sameDay,
      QuotaPresentation.compactUpdatedText(
        snapshot, mode: .absolute, now: now.addingTimeInterval(60), timeFormat: .hour12))
    let later = QuotaPresentation.compactUpdatedText(
      snapshot, mode: .absolute, now: now.addingTimeInterval(172800), timeFormat: .hour12)
    XCTAssertGreaterThan(later.count, sameDay.count)
    XCTAssertTrue(
      QuotaPresentation.observationDetails(snapshot, timeFormat: .hour12).contains(
        "Last read:"))
  }

  func testAvailableResetsTextNamesListedSubsetAndDropsPassedExpiry() throws {
    let expiry = try localDate(month: 12, day: 1, hour: 5, minute: 22)
    let before = expiry.addingTimeInterval(-(2 * 86400 + 3600))
    func text(_ resets: AvailableResets, _ mode: TimeDisplayMode = .absolute, now: Date? = nil)
      -> String?
    {
      QuotaPresentation.availableResetsText(
        resets, mode: mode, now: now ?? before, timeFormat: .hour12)
    }
    let all = AvailableResets(count: 3, listedCount: 3, earliestListedExpiry: expiry)
    XCTAssertEqual(text(all), "3 resets · Use by Dec 1, 5:22 AM")
    XCTAssertEqual(text(all, .relative), "3 resets · Expires in 2d 1h")
    let capped = AvailableResets(count: 5, listedCount: 1, earliestListedExpiry: expiry)
    XCTAssertEqual(text(capped), "5 resets · 1 listed · Use by Dec 1, 5:22 AM")
    XCTAssertEqual(text(AvailableResets(count: 1)), "1 reset held")
    // At and after the expiry the count is history, not an available entitlement.
    let one = AvailableResets(count: 1, listedCount: 1, earliestListedExpiry: expiry)
    XCTAssertEqual(
      text(one, now: expiry.addingTimeInterval(-60)), "1 reset · Use by Dec 1, 5:22 AM")
    XCTAssertEqual(text(one, now: expiry), "Last reported: 1 · Expiry passed")
    XCTAssertEqual(text(all, .relative, now: expiry + 1), "Last reported: 3 · Expiry passed")
    XCTAssertNil(text(AvailableResets(count: 0, listedCount: 0)))

    let cappedDetails = try XCTUnwrap(
      QuotaPresentation.availableResetsDetails(capped, now: before, timeFormat: .hour12))
    XCTAssertTrue(cappedDetails.contains("Earliest listed expiry: Dec 1, 2030 at 5:22 AM"))
    XCTAssertTrue(cappedDetails.contains("Unlisted resets may expire sooner"))
    let allDetails = try XCTUnwrap(
      QuotaPresentation.availableResetsDetails(all, now: expiry, timeFormat: .hour12))
    XCTAssertTrue(allDetails.hasPrefix("Last read reported 3 banked resets"))
    XCTAssertFalse(allDetails.contains("held"))
    XCTAssertTrue(allDetails.contains("Earliest reset expired"))
    XCTAssertFalse(allDetails.contains("Unlisted"))
  }

  /// Claude says which limits each reset restores; the panel names how many restore the weekly quota
  /// when that is not all of them, and the tooltip gives each group its own earliest expiry.
  func testAvailableResetsNamesWeeklySubsetOnlyWhenMixed() throws {
    let weeklyExpiry = try localDate(month: 12, day: 10, hour: 22, minute: 0)
    let otherExpiry = try localDate(year: 2031, month: 3, day: 9, hour: 7, minute: 59)
    let now = weeklyExpiry.addingTimeInterval(-15 * 86400)
    func text(_ resets: AvailableResets) -> String? {
      QuotaPresentation.availableResetsText(resets, mode: .absolute, now: now, timeFormat: .hour12)
    }
    let mixed = AvailableResets(
      count: 4, listedCount: 4, earliestListedExpiry: weeklyExpiry, weeklyCount: 1,
      weeklyEarliestExpiry: weeklyExpiry, otherEarliestExpiry: otherExpiry)
    XCTAssertEqual(text(mixed), "4 resets · 1 weekly · Use by Dec 10, 10:00 PM")
    let details = try XCTUnwrap(
      QuotaPresentation.availableResetsDetails(mixed, now: now, timeFormat: .hour12))
    XCTAssertTrue(details.hasPrefix("4 banked resets held."))
    XCTAssertTrue(
      details.contains("1 restores the weekly quota, earliest expiry Dec 10, 2030 at 10:00 PM."))
    XCTAssertTrue(
      details.contains("3 restore other limits only, earliest expiry Mar 9, 2031 at 7:59 AM."))
    // The other group can expire first; the panel date then follows it and the groups keep theirs.
    let otherFirst = AvailableResets(
      count: 4, listedCount: 4, earliestListedExpiry: weeklyExpiry, weeklyCount: 1,
      weeklyEarliestExpiry: otherExpiry, otherEarliestExpiry: weeklyExpiry)
    let otherFirstDetails = try XCTUnwrap(
      QuotaPresentation.availableResetsDetails(otherFirst, now: now, timeFormat: .hour12))
    XCTAssertTrue(
      otherFirstDetails.contains(
        "1 restores the weekly quota, earliest expiry Mar 9, 2031 at 7:59 AM."))
    XCTAssertTrue(
      otherFirstDetails.contains(
        "3 restore other limits only, earliest expiry Dec 10, 2030 at 10:00 PM."))

    let allWeekly = AvailableResets(
      count: 2, listedCount: 2, earliestListedExpiry: weeklyExpiry, weeklyCount: 2,
      weeklyEarliestExpiry: weeklyExpiry)
    XCTAssertEqual(text(allWeekly), "2 resets · Use by Dec 10, 10:00 PM")
    let noneWeekly = AvailableResets(
      count: 3, listedCount: 3, earliestListedExpiry: weeklyExpiry, weeklyCount: 0)
    XCTAssertEqual(text(noneWeekly), "3 resets · 0 weekly · Use by Dec 10, 10:00 PM")
    XCTAssertTrue(
      try XCTUnwrap(
        QuotaPresentation.availableResetsDetails(noneWeekly, now: now, timeFormat: .hour12)
      ).contains("None restores the weekly quota shown here."))
  }
}
