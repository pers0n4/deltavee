import AppKit
import DeltaveeCore
import SwiftUI
import XCTest

@testable import Deltavee

private actor UnavailableUpdateHTTP: UsageHTTPTransport {
  private(set) var count = 0
  func send(_ request: URLRequest) async throws -> HTTPResult {
    count += 1
    throw URLError(.notConnectedToInternet)
  }
}
private struct UpdateTestUsageCollector: Collector {
  let snapshot: QuotaSnapshot
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    .success(CollectedUsage(snapshot))
  }
}
// `lock` protects the test-only in-memory entries written from background tasks.
private final class UpdateTestLog: UpdateLogging, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [UpdateLogEntry] = []
  func append(_ entry: UpdateLogEntry) { lock.withLock { entries.append(entry) } }
}

final class UpdateNoticeTests: XCTestCase {
  @MainActor
  func testBundleMetadataMustProvideAStableVersionAndTheApprovedRepository() throws {
    XCTAssertEqual(failure(UpdateModel.configuration(info: nil)), .configuration)
    XCTAssertEqual(failure(UpdateModel.configuration(info: [:])), .configuration)
    XCTAssertEqual(
      failure(UpdateModel.configuration(info: ["CFBundleShortVersionString": "0.1.0"])),
      .configuration)
    XCTAssertEqual(
      failure(
        UpdateModel.configuration(info: [
          "CFBundleShortVersionString": "0.1.0", "DeltaveeUpdateRepository": "attacker/deltavee",
        ])), .configuration)
    let configuration = try UpdateModel.configuration(info: [
      "CFBundleShortVersionString": "0.1.0", "DeltaveeUpdateRepository": "pers0n4/deltavee",
    ]).get()
    XCTAssertEqual(configuration.currentVersion.description, "0.1.0")
  }

  @MainActor
  func testOnlyManualChecksShowFooterFeedback() throws {
    let current = try XCTUnwrap(StableVersion("0.1.0"))
    XCTAssertNil(UpdateModel(initialState: UpdateState(status: .current(current))).manualFeedback)
    XCTAssertNil(
      UpdateModel(initialState: UpdateState(status: .unavailable(.network))).manualFeedback)
    XCTAssertNil(
      UpdateModel(
        initialState: UpdateState(status: .available(try release())), hasRequestedCheck: true
      ).manualFeedback)
    XCTAssertEqual(
      UpdateModel(
        initialState: UpdateState(status: .unavailable(.network)), hasRequestedCheck: true
      ).manualFeedback, .unavailable(.network))
    XCTAssertNotEqual(
      UpdateCheckFeedbackView.statusMessage(for: .unavailable(.noRelease)),
      UpdateCheckFeedbackView.statusMessage(for: .current(current)))
    XCTAssertTrue(
      UpdateCheckFeedbackView.statusMessage(for: .unavailable(.configuration)).contains(
        "this build"))
  }

  @MainActor
  func testClosingPanelClearsManualFeedbackButKeepsAnAvailableRelease() throws {
    _ = NSApplication.shared
    let anchor = TestPanelAnchor()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let current = try XCTUnwrap(StableVersion("0.1.0"))
    let available = try release()
    let states = [
      UpdateState(status: .current(current)),
      UpdateState(status: .checking),
      UpdateState(status: .unavailable(.network), availableRelease: available),
    ]
    for state in states {
      let updates = UpdateModel(initialState: state, hasRequestedCheck: true)
      let model = AppModel(
        accountStore: AccountStore(directory: directory),
        snapshotStore: SnapshotStore(directory: directory), updates: updates)
      let controller = MenuPanelController(
        model: model, button: { anchor.button }, reduceMotion: { true },
        monitorsSystemEvents: false, screen: anchor.screen)
      defer { controller.shutdown() }

      controller.show()
      XCTAssertTrue(controller.isPresented)
      XCTAssertEqual(updates.manualFeedback, state.status)
      controller.hide()
      controller.show()
      XCTAssertTrue(controller.isPresented)
      XCTAssertNil(updates.manualFeedback, "Manual feedback must not return on reopen")
      XCTAssertEqual(updates.state.availableRelease, state.availableRelease)
    }
  }

  @MainActor
  func testManualUpdateNetworkFailureDoesNotAffectUsageCollectionOrAccountNotices() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = UnavailableUpdateHTTP()
    let checker = UpdateChecker(
      configuration: .success(
        try UpdateConfiguration(version: "0.1.0", repository: "pers0n4/deltavee")),
      transport: http, log: UpdateTestLog())
    let updates = UpdateModel(checker: checker)
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let snapshot = QuotaSnapshot(
      weeklyUsedPercent: 42, observedAt: now, fetchedAt: now, source: .codexAppServer)
    let collector = UpdateTestUsageCollector(snapshot: snapshot)
    let scheduler = Scheduler(codex: collector, claude: collector)
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory),
      makeScheduler: { _ in scheduler }, updates: updates)
    let account = Account(name: "Test", provider: .openai, configDir: "/fake/update-test")
    model.document.accounts = [account]
    model.notice = "Account settings need attention."
    model.refresh()
    await updates.checkNow()
    try await eventually {
      model.states[account.id]?.lastSuccess == snapshot
        && updates.state.status == .unavailable(.network)
    }
    XCTAssertEqual(model.notice, "Account settings need attention.")
    XCTAssertEqual(updates.manualFeedback, .unavailable(.network))
    await updates.checkNow()
    let count = await http.count
    XCTAssertEqual(count, 2, "A failed manual check remains retryable")
    await updates.stop()
    await scheduler.stop()
  }

  /// Set DELTAVEE_UPDATE_SCREENSHOTS=1 to save only temporary host renders, never README images.
  @MainActor
  func testEveryUpdateStateRendersAtPanelWidthWithoutOpeningTheBrowser() async throws {
    let version = try XCTUnwrap(StableVersion("0.1.0"))
    let cases: [(String, UpdateStatus)] = [
      ("checking", .checking), ("current", .current(version)),
      ("available", .available(try release())),
      ("network", .unavailable(.network)), ("no-release", .unavailable(.noRelease)),
      ("configuration", .unavailable(.configuration)), ("invalid", .unavailable(.invalidResponse)),
    ]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, status) in cases {
      for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let updates = UpdateModel(
          initialState: UpdateState(status: status), hasRequestedCheck: true)
        let model = AppModel(
          accountStore: AccountStore(directory: directory),
          snapshotStore: SnapshotStore(directory: directory),
          updates: updates)
        model.document.settings.transparentPanel = false
        model.document.accounts = [
          Account(name: "Test", provider: .openai, configDir: "/fake/update-test")
        ]
        let window = makeWindow(model: model, maxHeight: 520, appearance: appearance)
        defer {
          window.contentView = nil
          window.close()
        }
        try await settle(window)
        XCTAssertEqual(window.contentLayoutRect.width, PanelView.width, accuracy: 1)
        XCTAssertGreaterThan(window.contentLayoutRect.height, 100)
        XCTAssertLessThanOrEqual(window.contentLayoutRect.height, 520)
        if ProcessInfo.processInfo.environment["DELTAVEE_UPDATE_SCREENSHOTS"] == "1" {
          let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deltavee-update-notices", isDirectory: true)
          try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
          let view = try XCTUnwrap(window.contentView)
          let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
          view.cacheDisplay(in: view.bounds, to: bitmap)
          try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: output.appendingPathComponent("\(name)-\(theme).png"))
        }
      }
    }
  }

  @MainActor
  func testAvailableReleaseLinkStaysOutsideTheCappedAccountScrollArea() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let current = try XCTUnwrap(StableVersion("0.1.0"))
    let available = try release()
    var scrollSizes: [(viewport: CGFloat, document: CGFloat)] = []
    for status in [UpdateStatus.current(current), .available(available)] {
      let model = AppModel(
        accountStore: AccountStore(directory: directory),
        snapshotStore: SnapshotStore(directory: directory),
        updates: UpdateModel(initialState: UpdateState(status: status)))
      model.document.accounts = (0..<8).map {
        Account(name: "Test \($0)", provider: .openai, configDir: "/fake/\($0)", order: $0)
      }
      let window = makeWindow(model: model, maxHeight: 360, appearance: .aqua)
      defer {
        window.contentView = nil
        window.close()
      }
      try await settle(window)
      XCTAssertEqual(window.contentLayoutRect.height, 360, accuracy: 1)
      let scroll = try XCTUnwrap(findScroll(in: XCTUnwrap(window.contentView)))
      let document = try XCTUnwrap(scroll.documentView).bounds.height
      let viewport = scroll.contentView.bounds.height
      XCTAssertGreaterThan(document, viewport)
      XCTAssertGreaterThan(viewport, 1)
      scrollSizes.append((viewport, document))
    }
    XCTAssertLessThan(scrollSizes[1].viewport, scrollSizes[0].viewport)
    XCTAssertEqual(scrollSizes[1].document, scrollSizes[0].document, accuracy: 1)
  }

  @MainActor
  func testManualFeedbackStaysInFooterWhenAccountListIsCapped() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let current = try XCTUnwrap(StableVersion("0.1.0"))
    let available = try release()
    let cases: [UpdateStatus] = [.checking, .current(current), .unavailable(.network)]
    var baseline: CGFloat?
    for status in [UpdateStatus.available(available)] + cases {
      let updates = UpdateModel(
        initialState: UpdateState(status: status, availableRelease: available),
        hasRequestedCheck: true)
      let model = AppModel(
        accountStore: AccountStore(directory: directory),
        snapshotStore: SnapshotStore(directory: directory), updates: updates)
      model.document.accounts = (0..<8).map {
        Account(name: "Test \($0)", provider: .openai, configDir: "/fake/\($0)", order: $0)
      }
      let window = makeWindow(model: model, maxHeight: 360, appearance: .aqua)
      defer {
        window.contentView = nil
        window.close()
      }
      try await settle(window)
      XCTAssertEqual(window.contentLayoutRect.height, 360, accuracy: 1)
      let scroll = try XCTUnwrap(findScroll(in: XCTUnwrap(window.contentView)))
      let height = scroll.contentView.bounds.height
      if let baseline {
        XCTAssertLessThan(height, baseline, "Manual feedback must take up space in the footer")
      } else {
        baseline = height
      }
    }
  }

  @MainActor
  func testNoticeWrapsRatherThanShrinkingAtNarrowWidthsAndLongVersions() throws {
    _ = NSApplication.shared
    let long = try release(tag: "v18446744073709551616.18446744073709551616.18446744073709551616")
    let view = UpdateNoticeView(release: long)
    let wide = NSHostingView(rootView: view.frame(width: 288)).fittingSize
    let narrow = NSHostingView(rootView: view.frame(width: 160)).fittingSize
    XCTAssertEqual(wide.width, 288, accuracy: 1)
    XCTAssertEqual(narrow.width, 160, accuracy: 1)
    XCTAssertGreaterThan(narrow.height, wide.height)
  }

  private func failure(_ result: Result<UpdateConfiguration, UpdateFailure>) -> UpdateFailure? {
    if case .failure(let failure) = result { return failure }
    return nil
  }
  private func release(tag: String = "v0.2.0") throws -> ReleaseUpdate {
    try XCTUnwrap(
      ReleaseUpdate(tag: tag, url: "https://github.com/pers0n4/deltavee/releases/tag/\(tag)"))
  }
  @MainActor
  private func makeWindow(model: AppModel, maxHeight: CGFloat, appearance: NSAppearance.Name)
    -> NSWindow
  {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 1), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = NSHostingView(
      rootView: PanelView(
        model: model, maxHeight: maxHeight,
        onHeightChange: { [weak window] height in
          window?.setContentSize(NSSize(width: PanelView.width, height: height))
        }
      ).environment(
        \.openURL,
        OpenURLAction { _ in
          XCTFail("Rendering an update notice must not open the browser")
          return .handled
        }))
    return window
  }
  @MainActor
  private func settle(_ window: NSWindow) async throws {
    for _ in 0..<10 {
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  @MainActor
  private func findScroll(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
  }
  @MainActor
  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Update and usage tasks did not settle")
  }
}
