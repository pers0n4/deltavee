import DeltaveeCore
import Foundation
import XCTest

@testable import Deltavee

private actor RecordingCollector: Collector {
  private var counts: [UUID: Int] = [:]
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    counts[account.id, default: 0] += 1
    return .failure(CollectError(.authRequired))
  }
  func count(_ id: UUID) -> Int { counts[id, default: 0] }
}

private actor RateLimitedCollector: Collector {
  let retryAt: Date
  init(retryAt: Date) { self.retryAt = retryAt }
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    .failure(CollectError(.rateLimited, retryAt: retryAt))
  }
}

/// A clock whose time moves only through `advance(by:)`; sleepers resume once it reaches their deadline.
// `lock` guards `current` and `sleepers`; continuations are resumed after the lock is released.
private final class ManualClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }
  private struct Sleeper {
    let id: UUID
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }
  private let lock = NSLock()
  private var current = Instant(offset: .zero)
  private var sleepers: [Sleeper] = []
  var now: Instant { lock.withLock { current } }
  var minimumResolution: Duration { .zero }
  var pendingDeadlines: [Duration] { lock.withLock { sleepers.map(\.deadline.offset) } }
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let outcome: Result<Void, any Error>? = lock.withLock {
          if Task.isCancelled { return .failure(CancellationError()) }
          if deadline <= current { return .success(()) }
          sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return nil
        }
        if let outcome { continuation.resume(with: outcome) }
      }
    } onCancel: {
      let cancelled: Sleeper? = lock.withLock {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return sleepers.remove(at: index)
      }
      cancelled?.continuation.resume(throwing: CancellationError())
    }
  }
  func advance(by duration: Duration) {
    let due: [Sleeper] = lock.withLock {
      current = current.advanced(by: duration)
      let due = sleepers.filter { $0.deadline <= current }
      sleepers.removeAll { $0.deadline <= current }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}

final class AppModelTests: XCTestCase {
  @MainActor
  func testWakeRefreshesAllAccountsAndTicksOnlyAfterDelay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = Account(name: "Claude", provider: .anthropic, configDir: "/fake/claude")
    let second = Account(name: "Codex", provider: .openai, configDir: "/fake/codex")
    try AccountStore(directory: directory).save(AccountDocument(accounts: [first, second]))
    let collector = RecordingCollector()
    let scheduler = Scheduler(codex: collector, claude: collector)
    let clock = ManualClock()
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory), makeScheduler: { _ in scheduler },
      clock: clock)
    model.refresh()
    try await wait { model.refreshingAccountIDs.isEmpty }
    let early: Duration = .seconds(4)
    XCTAssertLessThan(
      early, AppModel.wakeRefreshDelay, "The early step must stop short of the delay")
    XCTAssertEqual(AppModel.wakeRefreshDelay, .seconds(5))

    model.now = .distantPast
    model.systemDidWake()
    try await wait { clock.pendingDeadlines == [AppModel.wakeRefreshDelay] }
    clock.advance(by: early)
    try await Task.sleep(for: .milliseconds(50))
    var counts = await (collector.count(first.id), collector.count(second.id))
    XCTAssertEqual(counts.0, 1)
    XCTAssertEqual(counts.1, 1)
    XCTAssertEqual(model.now, .distantPast, "No tick before the delay elapses")

    clock.advance(by: AppModel.wakeRefreshDelay - early)
    try await wait { model.now != .distantPast }
    try await waitAsync {
      await (collector.count(first.id), collector.count(second.id)) == (2, 2)
    }
    try await wait { model.refreshingAccountIDs.isEmpty }
    counts = await (collector.count(first.id), collector.count(second.id))
    XCTAssertEqual(counts.0, 2)
    XCTAssertEqual(counts.1, 2)
    await scheduler.stop()
  }

  /// Without accounts no fetch result ticks the model, so only the wake handler can update `now`.
  @MainActor
  func testWakeTicksEvenWhenNoFetchCompletes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scheduler = Scheduler(codex: RecordingCollector(), claude: RecordingCollector())
    let clock = ManualClock()
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory), makeScheduler: { _ in scheduler },
      clock: clock)
    XCTAssertTrue(model.document.accounts.isEmpty)
    model.now = .distantPast
    model.systemDidWake()
    try await wait { clock.pendingDeadlines == [AppModel.wakeRefreshDelay] }
    clock.advance(by: AppModel.wakeRefreshDelay)
    try await wait { model.now != .distantPast }
    await scheduler.stop()
  }

  @MainActor
  func testRepeatedWakeRestartsTheDelayAndRefreshesOnce() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = Account(name: "Codex", provider: .openai, configDir: "/fake/codex")
    try AccountStore(directory: directory).save(AccountDocument(accounts: [account]))
    let collector = RecordingCollector()
    let scheduler = Scheduler(codex: collector, claude: collector)
    let clock = ManualClock()
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory), makeScheduler: { _ in scheduler },
      clock: clock)
    model.refresh()
    try await wait { model.refreshingAccountIDs.isEmpty }

    model.systemDidWake()
    try await wait { clock.pendingDeadlines == [.seconds(5)] }
    clock.advance(by: .seconds(3))
    model.systemDidWake()
    // The first wait is cancelled and only the second, ending at 3 s + 5 s, remains.
    try await wait { clock.pendingDeadlines == [.seconds(8)] }
    clock.advance(by: .seconds(3))
    XCTAssertGreaterThan(clock.now.offset, .seconds(5), "Past the first wake's deadline")
    try await Task.sleep(for: .milliseconds(50))
    var count = await collector.count(account.id)
    XCTAssertEqual(count, 1, "The replaced wake does not refresh")

    clock.advance(by: .seconds(2))
    try await waitAsync { await collector.count(account.id) == 2 }
    try await wait { model.refreshingAccountIDs.isEmpty }
    try await Task.sleep(for: .milliseconds(50))
    count = await collector.count(account.id)
    XCTAssertEqual(count, 2, "Two wakes within the delay refresh once")
    XCTAssertTrue(clock.pendingDeadlines.isEmpty)
    await scheduler.stop()
  }

  @MainActor
  func testRateLimitReleaseSurvivesRelaunchAndBlocksFetches() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let claude = Account(name: "Claude", provider: .anthropic, configDir: "/fake/claude")
    let codex = Account(name: "Codex", provider: .openai, configDir: "/fake/codex")
    try AccountStore(directory: directory).save(AccountDocument(accounts: [claude, codex]))
    // Whole seconds survive the JSON round trip exactly.
    let release = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded())
    let limited = Scheduler(
      codex: RecordingCollector(), claude: RateLimitedCollector(retryAt: release))
    let first = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory), makeScheduler: { _ in limited })
    first.refresh()
    try await wait { first.refreshingAccountIDs.isEmpty }
    await limited.stop()
    XCTAssertEqual(first.rateLimitHolds, [claude.id: release])
    XCTAssertTrue(first.isRateLimitHeld(claude.id))
    XCTAssertEqual(try RateLimitStore(directory: directory).load(), [claude.id: release])

    let collector = RecordingCollector()
    let scheduler = Scheduler(codex: collector, claude: collector)
    let relaunched = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory), makeScheduler: { _ in scheduler })
    XCTAssertEqual(relaunched.rateLimitHolds, [claude.id: release])
    relaunched.refresh()
    XCTAssertEqual(
      relaunched.refreshingAccountIDs, [codex.id], "Held accounts are not shown as refreshing")
    try await wait { relaunched.refreshingAccountIDs.isEmpty }
    relaunched.refresh(accountID: claude.id)
    XCTAssertTrue(relaunched.refreshingAccountIDs.isEmpty, "Manual refresh is ignored while held")
    try await Task.sleep(for: .milliseconds(50))
    let claudeCount = await collector.count(claude.id)
    let codexCount = await collector.count(codex.id)
    XCTAssertEqual(claudeCount, 0)
    XCTAssertEqual(codexCount, 1)

    // Statusline-only collection never calls the rate-limited endpoint, so the hold does not apply.
    var document = relaunched.document
    document.settings.claudeSource = .statuslineOnly
    relaunched.save(document)
    XCTAssertFalse(relaunched.isRateLimitHeld(claude.id))
    try await wait { relaunched.refreshingAccountIDs.isEmpty }
    let statuslineCount = await collector.count(claude.id)
    XCTAssertEqual(statuslineCount, 1)
    XCTAssertEqual(
      relaunched.rateLimitHolds, [claude.id: release], "The release time is kept for OAuth")
    await scheduler.stop()
  }

  @MainActor
  func testAccountRefreshTargetsOnlySelectedAccountAndClearsBusyState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = Account(name: "Claude", provider: .anthropic, configDir: "/fake/claude")
    let second = Account(name: "Codex", provider: .openai, configDir: "/fake/codex")
    let accounts = AccountStore(directory: directory)
    try accounts.save(AccountDocument(accounts: [first, second]))
    let collector = RecordingCollector()
    let scheduler = Scheduler(codex: collector, claude: collector)
    let model = AppModel(
      accountStore: accounts, snapshotStore: SnapshotStore(directory: directory),
      makeScheduler: { _ in scheduler })
    model.refresh()
    try await wait { model.refreshingAccountIDs.isEmpty }
    let firstBefore = await collector.count(first.id)
    let secondBefore = await collector.count(second.id)
    XCTAssertEqual(firstBefore, 1)
    XCTAssertEqual(secondBefore, 1)
    let secondState = model.states[second.id]
    model.refresh(accountID: first.id)
    XCTAssertEqual(model.refreshingAccountIDs, [first.id])
    try await wait { model.refreshingAccountIDs.isEmpty }
    let firstAfter = await collector.count(first.id)
    let secondAfter = await collector.count(second.id)
    XCTAssertEqual(firstAfter, 2)
    XCTAssertEqual(secondAfter, 1)
    XCTAssertEqual(model.states[second.id], secondState)
    XCTAssertEqual(model.states[first.id], .authRequired(lastSuccess: nil))
    model.refresh(accountID: UUID())
    XCTAssertTrue(model.refreshingAccountIDs.isEmpty)
    await scheduler.stop()
  }

  @MainActor
  func testSaveRestartsCollectionOnlyWhenCollectionInputsChange() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = Account(name: "Claude", provider: .anthropic, configDir: "/fake/claude", order: 0)
    let second = Account(name: "Codex", provider: .openai, configDir: "/fake/codex", order: 1)
    let collector = RecordingCollector()
    let scheduler = Scheduler(codex: collector, claude: collector)
    var made = 0
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory),
      makeScheduler: { _ in
        made += 1
        return scheduler
      })
    model.save(AccountDocument(accounts: [first, second]))
    XCTAssertEqual(made, 1)
    var document = model.document
    document.settings.theme = .dark
    document.settings.mode = .remaining
    document.settings.colorMenuBarUsage = true
    document.accounts.swapAt(0, 1)
    document.accounts[0].name = "Work"
    document.accounts[1].showInIcon = false
    model.save(document)
    XCTAssertEqual(made, 1, "Display, order, label, and visibility edits keep collection running")
    XCTAssertEqual(try AccountStore(directory: directory).load(), document)
    for change in [
      { (d: inout AccountDocument) in d.settings.codexPath = "/fake/bin/codex" },
      { $0.settings.claudePath = "/fake/bin/claude" },
      { $0.settings.claudeSource = .statuslineOnly },
      { $0.settings.intervalSeconds = 180 },
      { $0.accounts[0].configDir = "/fake/other" },
      { $0.accounts[1].provider = .openai },
      { $0.accounts.removeLast() },
    ] as [(inout AccountDocument) -> Void] {
      let before = made
      var changed = model.document
      change(&changed)
      model.save(changed)
      XCTAssertEqual(made, before + 1)
    }
    try await wait { model.refreshingAccountIDs.isEmpty }
    await scheduler.stop()
  }

  @MainActor
  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for model refresh")
  }

  @MainActor
  private func waitAsync(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for collector fetches")
  }
}
