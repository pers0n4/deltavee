import AppKit
import DeltaveeCore
import SwiftUI
import XCTest

@testable import Deltavee

/// Reports one email on every fetch, so an unlabeled account shows it in the panel.
private struct FixedEmailCollector: Collector {
  let email: String
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    .failure(CollectError(.authRequired, email: .address(email)))
  }
}

final class PanelSizingTests: XCTestCase {
  /// The reset and Updated times fit one line at full size, without the shrink fallback, for
  /// every month, the widest clock times, and every display mode and time format.
  @MainActor
  func testAccountMetaLineFitsOneLineAtPanelWidthWithoutShrinking() throws {
    _ = NSApplication.shared
    let available = PanelView.width - 2 * AccountMetaLine.rowInset
    let calendar = Calendar.current
    for month in 1...12 {
      let reset = try XCTUnwrap(
        calendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: 23, minute: 58))
      )
      let noon = try XCTUnwrap(
        calendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: 12, minute: 58))
      )
      let now = try XCTUnwrap(calendar.date(byAdding: .day, value: 29, to: noon))
      for observedAt in [noon, reset] {
        let snapshot = QuotaSnapshot(
          weeklyUsedPercent: 100, weeklyResetsAt: observedAt == noon ? noon : reset,
          observedAt: observedAt, fetchedAt: now, source: .claudeOAuth)
        for resetMode in [TimeDisplayMode.absolute, .relative] {
          for updatedMode in [TimeDisplayMode.absolute, .relative] {
            for format in TimeFormat.allCases {
              let line = AccountMetaLine(
                snapshot: snapshot, now: now, resetTimeMode: resetMode,
                updatedTimeMode: updatedMode, timeFormat: format)
              let width = NSHostingView(rootView: line.fixedSize()).fittingSize.width
              XCTAssertLessThanOrEqual(
                width, available,
                "Meta line for month \(month), \(resetMode)/\(updatedMode)/\(format) needs \(width)pt"
              )
            }
          }
        }
      }
    }
  }

  /// The banked-reset line fits one line at panel width with two-digit counts, for Codex's listed
  /// subset and Claude's weekly subset, every month, the widest clock time, and every display mode and
  /// time format.
  @MainActor
  func testAvailableResetsLineFitsOneLineAtPanelWidth() throws {
    _ = NSApplication.shared
    let available = PanelView.width - 2 * AccountMetaLine.rowInset
    let calendar = Calendar.current
    for month in 1...12 {
      let expiry = try XCTUnwrap(
        calendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: 23, minute: 58))
      )
      let codex = AvailableResets(count: 99, listedCount: 88, earliestListedExpiry: expiry)
      let claude = AvailableResets(
        count: 99, listedCount: 99, earliestListedExpiry: expiry, weeklyCount: 88,
        weeklyEarliestExpiry: expiry)
      // Just under 30 days out gives the longest countdown, `Expires in 29d 23h 59m`.
      let now = expiry.addingTimeInterval(-(30 * 86400 - 61))
      for resets in [codex, claude] {
        for mode in [TimeDisplayMode.absolute, .relative] {
          for format in TimeFormat.allCases {
            let line = AvailableResetsLine(
              resets: resets, now: now, resetTimeMode: mode, timeFormat: format)
            let width = NSHostingView(rootView: line.fixedSize()).fittingSize.width
            XCTAssertGreaterThan(width, 0)
            XCTAssertLessThanOrEqual(
              width, available, "Resets line for month \(month), \(mode)/\(format) needs \(width)pt"
            )
          }
        }
      }
    }
  }

  /// Each note fits the panel width for every month, the widest clock times, the 24-hour maximum
  /// wait, and every display mode and time format. Both share one line unless the resume time is
  /// on another day; that case falls back to two lines in `AccountStatusLine`.
  @MainActor
  func testRateLimitNoteFitsOneLineAtPanelWidth() throws {
    _ = NSApplication.shared
    let available = PanelView.width - 2 * AccountMetaLine.rowInset
    let calendar = Calendar.current
    for month in 1...12 {
      let release = try XCTUnwrap(
        calendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: 23, minute: 58))
      )
      for now in [release.addingTimeInterval(-3600), release.addingTimeInterval(-86399)] {
        for mode in [TimeDisplayMode.absolute, .relative] {
          for format in TimeFormat.allCases {
            func width(stale: Bool, held: Bool) -> CGFloat {
              NSHostingView(
                rootView: AccountStatusLine(
                  stale: stale, heldUntil: held ? release : nil, now: now, resetTimeMode: mode,
                  timeFormat: format
                ).fixedSize()
              ).fittingSize.width
            }
            let label = "month \(month), \(mode)/\(format)"
            let note = width(stale: false, held: true)
            XCTAssertLessThanOrEqual(note, available, "Resume note for \(label) needs \(note)pt")
            let shared = width(stale: true, held: false) + 8 + note
            if mode == .relative || calendar.isDate(release, inSameDayAs: now) {
              XCTAssertLessThanOrEqual(
                shared, available, "Shared line for \(label) needs \(shared)pt")
            }
          }
        }
      }
    }
  }

  @MainActor
  func testPanelGrowsAndShrinksWithAccountsDetailsAndNotice() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    let window = makeWindow(model: model, maxHeight: 600)
    defer {
      window.contentView = nil
      window.close()
    }
    try await settle(window)
    let empty = window.contentLayoutRect.height
    XCTAssertGreaterThan(empty, 100)
    // Empty-state prompt with its Add Account menu plus five footer actions.
    XCTAssertLessThan(empty, 300)

    let first = Account(name: "Claude", provider: .anthropic, configDir: "/fake/claude")
    model.document.accounts = [first]
    try await settle(window)
    let oneAccount = window.contentLayoutRect.height
    XCTAssertGreaterThan(oneAccount, empty)

    let now = Date()
    model.states[first.id] = .failed(
      .rateLimited,
      lastSuccess: QuotaSnapshot(
        weeklyUsedPercent: 42, weeklyResetsAt: now.addingTimeInterval(3600),
        observedAt: now.addingTimeInterval(-7200), fetchedAt: now, source: .claudeOAuth))
    try await settle(window)
    let withDetails = window.contentLayoutRect.height
    XCTAssertGreaterThan(withDetails, oneAccount)

    let second = Account(name: "Codex", provider: .openai, configDir: "/fake/codex", order: 1)
    model.document.accounts.append(second)
    try await settle(window)
    XCTAssertGreaterThan(window.contentLayoutRect.height, withDetails)
    model.document.accounts.removeLast()
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, withDetails, accuracy: 1)

    model.states.removeAll()
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, oneAccount, accuracy: 1)
    model.document.accounts.removeAll()
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, empty, accuracy: 1)

    model.notice = "설정 저장을 완료하지 못했습니다.\n설정 디렉터리의 접근 권한을 확인하세요."
    try await settle(window)
    XCTAssertGreaterThan(window.contentLayoutRect.height, empty)
    model.notice = nil
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, empty, accuracy: 1)
    XCTAssertEqual(window.contentLayoutRect.width, PanelView.width, accuracy: 1)
  }

  @MainActor
  func testManyAccountsScrollAtHeightLimitAndShrinkAfterRemoval() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    model.document.accounts = (0..<12).map { index in
      Account(name: "계정 \(index)", provider: .openai, configDir: "/fake/\(index)", order: index)
    }
    let window = makeWindow(model: model, maxHeight: 360)
    defer {
      window.contentView = nil
      window.close()
    }
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, 360, accuracy: 1)
    let scroll = try XCTUnwrap(findScrollView(in: window.contentView!))
    XCTAssertGreaterThan(
      try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height)
    XCTAssertLessThan(scroll.bounds.height, window.contentLayoutRect.height - 90)

    model.document.accounts = [model.document.accounts[0]]
    try await settle(window)
    XCTAssertLessThan(window.contentLayoutRect.height, 360)
    XCTAssertGreaterThan(window.contentLayoutRect.height, 100)
  }

  @MainActor
  func testAccountsUseAvailableHeightBeyondSixHundredBeforeScrolling() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    model.document.accounts = (0..<7).map {
      Account(name: "Account \($0)", provider: .openai, configDir: "/fake/\($0)", order: $0)
    }
    let window = makeWindow(model: model, maxHeight: 1000)
    defer {
      window.contentView = nil
      window.close()
    }
    try await settle(window)
    XCTAssertGreaterThan(window.contentLayoutRect.height, 600)
    XCTAssertLessThan(window.contentLayoutRect.height, 1000)
    let scroll = try XCTUnwrap(findScrollView(in: window.contentView!))
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height + 1)
    let host = try XCTUnwrap(window.contentView as? NSHostingView<PanelView>)
    host.rootView.maxHeight = 500
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, 500, accuracy: 1)
    host.rootView.maxHeight = 1000
    try await settle(window)
    XCTAssertGreaterThan(window.contentLayoutRect.height, 600)
    XCTAssertLessThan(window.contentLayoutRect.height, 1000)
    model.document.accounts += (7..<15).map {
      Account(name: "Account \($0)", provider: .openai, configDir: "/fake/\($0)", order: $0)
    }
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, 1000, accuracy: 1)
    XCTAssertGreaterThan(
      try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height)
  }

  @MainActor
  func testSettingsNavigationUsesSameWindowAndEscapeReturnsToAccounts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    let window = makeWindow(model: model, maxHeight: 800)
    defer {
      window.contentView = nil
      window.close()
    }
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderFront(nil)
    try await settle(window)
    let count = NSApp.windows.count
    let originalHeight = window.contentLayoutRect.height
    let open = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: ",",
        charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
    XCTAssertTrue(window.performKeyEquivalent(with: open))
    try await settle(window)
    XCTAssertEqual(NSApp.windows.count, count)
    XCTAssertEqual(window.contentLayoutRect.width, PanelView.width, accuracy: 1)
    XCTAssertLessThanOrEqual(window.contentLayoutRect.height, 800)
    XCTAssertGreaterThan(window.contentLayoutRect.height, originalHeight)
    let cancel = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    XCTAssertTrue(window.performKeyEquivalent(with: cancel))
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, originalHeight, accuracy: 1)
    XCTAssertEqual(NSApp.windows.count, count)
    XCTAssertTrue(window.performKeyEquivalent(with: open))
    try await settle(window)
    let returnKey = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    XCTAssertFalse(
      window.performKeyEquivalent(with: returnKey), "Settings apply live; Return is not Save")
    XCTAssertTrue(window.performKeyEquivalent(with: cancel))
    try await settle(window)
    XCTAssertEqual(window.contentLayoutRect.height, originalHeight, accuracy: 1)
    XCTAssertEqual(NSApp.windows.count, count)
    XCTAssertEqual(try AccountStore(directory: directory).load(), model.document)
  }

  @MainActor
  func testUsageBarsRenderAllSeverityColorsInUsedAndRemainingModes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    let now = Date()
    for (index, used) in [10.0, 75, 95].enumerated() {
      let account = Account(
        name: "Account \(index)", provider: .anthropic, configDir: "/fake/\(index)", order: index)
      model.document.accounts.append(account)
      model.states[account.id] = .ok(
        QuotaSnapshot(
          weeklyUsedPercent: used, observedAt: now, fetchedAt: now, source: .claudeStatusline))
    }
    let window = makeWindow(model: model, maxHeight: 1000)
    defer {
      window.contentView = nil
      window.close()
    }
    for mode in PercentMode.allCases {
      model.document.settings.mode = mode
      try await settle(window)
      let view = try XCTUnwrap(window.contentView)
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      var teal = 0
      var orange = 0
      var red = 0
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
            color.alphaComponent > 0.9
          else { continue }
          let r = color.redComponent
          let g = color.greenComponent
          let b = color.blueComponent
          if g > r * 1.4 && b > r * 1.3 { teal += 1 }
          if r > b * 1.6 && g > b * 1.2 && r > g * 1.1 { orange += 1 }
          if r > g * 1.7 && r > b * 1.5 { red += 1 }
        }
      }
      XCTAssertGreaterThan(teal, 10, "Healthy quota must render teal in \(mode)")
      XCTAssertGreaterThan(orange, 10, "Warning quota must render orange in \(mode)")
      XCTAssertGreaterThan(red, 10, "Critical quota must render red in \(mode)")
    }
  }

  @MainActor
  func testTransparentPanelOptionControlsOpaqueBackgroundFill() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    model.document.accounts = [Account(name: "", provider: .anthropic, configDir: "/fake")]
    let window = makeWindow(model: model, maxHeight: 800)
    defer {
      window.contentView = nil
      window.close()
    }
    func opaqueFraction() throws -> Double {
      let bitmap = try snapshot(window)
      var opaque = 0
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide
        where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.99 {
          opaque += 1
        }
      }
      return Double(opaque) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
    }
    XCTAssertTrue(model.document.settings.transparentPanel)
    try await settle(window)
    XCTAssertLessThan(
      try opaqueFraction(), 0.5, "Transparent panel must leave the material visible")
    model.document.settings.transparentPanel = false
    try await settle(window)
    XCTAssertGreaterThan(try opaqueFraction(), 0.99, "Opaque panel must fill its whole surface")
  }

  /// The material's maskImage does not clip SwiftUI content, so the opaque fill must round its own
  /// corners or the square fill reappears over light windows.
  @MainActor
  func testOpaquePanelFillLeavesCornersTransparent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    model.document.accounts = [Account(name: "", provider: .anthropic, configDir: "/fake")]
    model.document.settings.transparentPanel = false
    let window = makeWindow(model: model, maxHeight: 800)
    defer {
      window.contentView = nil
      window.close()
    }
    try await settle(window)
    let bitmap = try snapshot(window)
    let size = try XCTUnwrap(window.contentView).bounds.size
    XCTAssertGreaterThan(size.height, PanelView.cornerRadius * 2)
    let scale = CGFloat(bitmap.pixelsWide) / size.width
    // Points from the top-left of the view; colorAt(x:y:) also counts rows from the top.
    func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
      bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? -1
    }
    let radius = PanelView.cornerRadius
    let (maxX, maxY) = (size.width - 1, size.height - 1)
    for (x, y) in [(0.5, 0.5), (maxX + 0.5, 0.5), (0.5, maxY + 0.5), (maxX + 0.5, maxY + 0.5)] {
      XCTAssertLessThan(alpha(x, y), 0.01, "corner (\(x), \(y)) must stay transparent")
    }
    let inset = radius / 2
    for (x, y) in [
      (inset, inset), (size.width - inset, inset), (inset, size.height - inset),
      (size.width - inset, size.height - inset),
    ] {
      XCTAssertGreaterThan(alpha(x, y), 0.99, "arc (\(x), \(y)) must stay opaque")
    }
    XCTAssertGreaterThan(alpha(0.5, size.height / 2), 0.99)
    XCTAssertGreaterThan(alpha(size.width / 2, 0.5), 0.99)
  }

  @MainActor
  private func snapshot(_ window: NSWindow) throws -> NSBitmapImageRep {
    let view = try XCTUnwrap(window.contentView)
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
  }

  @MainActor
  func testOptionalLabelOnlyAddsHeightWhenPresent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    let account = Account(name: "", provider: .anthropic, configDir: "/fake")
    model.document.accounts = [account]
    let window = makeWindow(model: model, maxHeight: 800)
    defer {
      window.contentView = nil
      window.close()
    }
    try await settle(window)
    let baseHeight = window.contentLayoutRect.height
    model.document.accounts[0].name = "Work account"
    try await settle(window)
    XCTAssertGreaterThan(window.contentLayoutRect.height, baseHeight)
    for name in ["", " \n", "Claude", "claude"] {
      model.document.accounts[0].name = name
      try await settle(window)
      XCTAssertEqual(window.contentLayoutRect.height, baseHeight, accuracy: 1)
    }
    XCTAssertEqual(model.document.accounts[0].id, account.id)
  }

  /// A long email keeps its domain end visible, while a long user label keeps its start.
  @MainActor
  func testLongEmailKeepsItsEndWhileLongLabelKeepsItsStart() async throws {
    let local = "alexandra.konstantinopoulou.platform-team"
    let emails = ["\(local)@north-region.example.com", "\(local)@north-region.example.org"]
    let font = NSFont.preferredFont(forTextStyle: .caption1)
    for email in emails {
      XCTAssertGreaterThan(
        (email as NSString).size(withAttributes: [.font: font]).width, PanelView.width,
        "The email must be wider than the panel so it is cut")
    }
    let emailRows = try await [
      panelBitmap(name: "", email: emails[0]),
      panelBitmap(name: "", email: emails[1]),
    ]
    XCTAssertNotEqual(
      emailRows[0].tiffRepresentation, emailRows[1].tiffRepresentation,
      "Emails differing only at the end must look different")
    // The same strings as labels: cutting the end makes them look the same.
    let labelRows = try await [
      panelBitmap(name: emails[0], email: emails[0]),
      panelBitmap(name: emails[1], email: emails[0]),
    ]
    XCTAssertEqual(
      labelRows[0].tiffRepresentation, labelRows[1].tiffRepresentation,
      "A label keeps its start and loses its end")
  }

  @MainActor
  private func panelBitmap(name: String, email: String) async throws -> NSBitmapImageRep {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let collector = FixedEmailCollector(email: email)
    let scheduler = Scheduler(codex: collector, claude: collector)
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory), makeScheduler: { _ in scheduler })
    model.save(
      AccountDocument(accounts: [Account(name: name, provider: .openai, configDir: "/fake/codex")]))
    for _ in 0..<200 where model.detectedEmails.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    await scheduler.stop()
    XCTAssertEqual(model.detectedEmails.values.first, email)
    let window = makeWindow(model: model, maxHeight: 800)
    defer {
      window.contentView = nil
      window.close()
    }
    window.appearance = NSAppearance(named: .darkAqua)
    try await settle(window)
    return try snapshot(window)
  }

  @MainActor
  private func makeWindow(model: AppModel, maxHeight: CGFloat) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 1), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: PanelView(
        model: model, maxHeight: maxHeight,
        onHeightChange: { [weak window] height in
          window?.setContentSize(NSSize(width: PanelView.width, height: height))
        }))
    return window
  }

  @MainActor
  private func settle(_ window: NSWindow) async throws {
    // Let geometry preferences and the resulting AppKit resize complete both layout passes.
    for _ in 0..<10 {
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @MainActor
  private func findScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
  }
}
