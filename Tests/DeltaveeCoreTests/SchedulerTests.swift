import XCTest

@testable import DeltaveeCore

private struct FixedCollector: Collector {
  let result: Result<CollectedUsage, CollectError>
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> { result }
}
/// Sends each account to its own collector; unlisted accounts succeed. Counts every fetch.
private actor RoutingCollector: Collector {
  let routes: [UUID: any Collector]
  private var counts: [UUID: Int] = [:]
  init(_ routes: [UUID: any Collector]) { self.routes = routes }
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    counts[account.id, default: 0] += 1
    guard let route = routes[account.id] else {
      return .success(
        CollectedUsage(
          QuotaSnapshot(
            weeklyUsedPercent: 10, observedAt: Date(), fetchedAt: Date(), source: .claudeOAuth)))
    }
    return await route.fetch(account)
  }
  func count(_ id: UUID) -> Int { counts[id, default: 0] }
}
private actor CountingCollector: Collector {
  var count = 0
  let result: Result<CollectedUsage, CollectError>
  init(_ result: Result<CollectedUsage, CollectError>) { self.result = result }
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    count += 1
    return result
  }
}
private actor ErrorRecorder {
  var errors: [CollectError] = []
  func record(_ result: Result<CollectedUsage, CollectError>) {
    if case .failure(let error) = result { errors.append(error) }
  }
}
private actor ResultRecorder {
  var values: [UUID: Bool] = [:]
  var counts: [UUID: Int] = [:]
  func record(_ account: Account, _ result: Result<CollectedUsage, CollectError>) {
    counts[account.id, default: 0] += 1
    if case .success = result { values[account.id] = true } else { values[account.id] = false }
  }
}
private actor ControlledCollector: Collector {
  var starts: [UUID: Int] = [:]
  var cancellations: [UUID: Int] = [:]
  var active: [UUID: Int] = [:]
  var peak: [UUID: Int] = [:]
  private var pending: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    starts[account.id, default: 0] += 1
    active[account.id, default: 0] += 1
    peak[account.id] = max(peak[account.id, default: 0], active[account.id, default: 0])
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pending[account.id, default: []].append(continuation)
      }
    } onCancel: {
      Task { await self.cancelled(account.id) }
    }
    active[account.id, default: 0] -= 1
    return .failure(CollectError(.schema))
  }
  private func cancelled(_ id: UUID) { cancellations[id, default: 0] += 1 }
  func finish(_ id: UUID) {
    guard var continuations = pending[id], !continuations.isEmpty else { return }
    let continuation = continuations.removeFirst()
    pending[id] = continuations
    continuation.resume()
  }
}
/// A clock and a pause whose time moves only through `advance(to:)`.
// `lock` guards `current` and `sleepers`; continuations are resumed after the lock is released.
private final class ManualTime: UsageClock, @unchecked Sendable {
  private struct Sleeper {
    let id: UUID
    let deadline: Date
    let continuation: CheckedContinuation<Void, any Error>
  }
  private let lock = NSLock()
  private var current: Date
  private var sleepers: [Sleeper] = []
  init(_ start: Date) { current = start }
  func now() -> Date { lock.withLock { current } }
  var sleeping: Int { lock.withLock { sleepers.count } }
  func pause(_ seconds: TimeInterval) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let due: Bool = lock.withLock {
          let deadline = current.addingTimeInterval(seconds)
          if Task.isCancelled || deadline <= current { return true }
          sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return false
        }
        if due {
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            continuation.resume()
          }
        }
      }
    } onCancel: {
      let cancelled: Sleeper? = lock.withLock {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return sleepers.remove(at: index)
      }
      cancelled?.continuation.resume(throwing: CancellationError())
    }
  }
  func advance(to date: Date) {
    let due: [Sleeper] = lock.withLock {
      current = date
      let due = sleepers.filter { $0.deadline <= date }
      sleepers.removeAll { $0.deadline <= date }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}
/// Holds its first fetch until `open()`, then answers it with a rate limit even if cancelled,
/// like a response that already arrived. Later fetches fail with a schema error.
private actor GatedRateLimitCollector: Collector {
  let retryAt: Date
  private(set) var fetches = 0
  private var gate: CheckedContinuation<Void, Never>?
  private(set) var cancelled = false
  init(retryAt: Date) { self.retryAt = retryAt }
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    fetches += 1
    guard fetches == 1 else { return .failure(CollectError(.schema)) }
    await withTaskCancellationHandler {
      await withCheckedContinuation { gate = $0 }
    } onCancel: {
      Task { await self.markCancelled() }
    }
    return .failure(CollectError(.rateLimited, retryAt: retryAt))
  }
  private func markCancelled() { cancelled = true }
  var waiting: Bool { gate != nil }
  func open() {
    gate?.resume()
    gate = nil
  }
}

final class SchedulerTests: CoreTestCase {
  private func eventually(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
      if await predicate() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
  func testAccountRefreshIsIsolatedAndRepeatedRefreshWaitsForCancelledFetch() async {
    let first = account(.openai)
    let second = account(.anthropic)
    let collector = ControlledCollector()
    let recorder = ResultRecorder()
    let scheduler = Scheduler(codex: collector, claude: collector)
    await scheduler.start(accounts: [first, second], interval: 600) {
      await recorder.record($0, $1)
    }
    let started = await eventually { await collector.starts.values.reduce(0, +) == 2 }
    XCTAssertTrue(started)
    let refresh = Task { await scheduler.refresh(accountID: first.id) }
    let cancelled = await eventually { await collector.cancellations[first.id] == 1 }
    XCTAssertTrue(cancelled)
    var repeatedRequested = false
    let repeated = Task {
      repeatedRequested = true
      await scheduler.refresh(accountID: first.id)
    }
    let queued = await eventually { repeatedRequested }
    XCTAssertTrue(queued)
    await scheduler.refresh(accountID: UUID())
    let before = await collector.starts
    XCTAssertEqual(before[first.id], 1)
    XCTAssertEqual(before[second.id], 1)
    await collector.finish(first.id)
    await refresh.value
    await repeated.value
    let restarted = await eventually { await collector.starts[first.id] == 2 }
    XCTAssertTrue(restarted)
    await collector.finish(first.id)
    await collector.finish(second.id)
    let delivered = await eventually { await recorder.counts.count == 2 }
    XCTAssertTrue(delivered)
    await scheduler.stop()
    let counts = await recorder.counts
    let starts = await collector.starts
    let peaks = await collector.peak
    XCTAssertEqual(counts[first.id], 1)
    XCTAssertEqual(counts[second.id], 1)
    XCTAssertEqual(starts[second.id], 1)
    XCTAssertEqual(peaks[first.id], 1)
  }
  func testStopDuringRefreshSuppressesResultsAndDoesNotRestart() async {
    let a = account(.openai)
    let collector = ControlledCollector()
    let recorder = ResultRecorder()
    let scheduler = Scheduler(codex: collector, claude: collector)
    await scheduler.start(accounts: [a], interval: 600) { await recorder.record($0, $1) }
    let started = await eventually { await collector.starts[a.id] == 1 }
    XCTAssertTrue(started)
    let refresh = Task { await scheduler.refresh(accountID: a.id) }
    let cancelled = await eventually { await collector.cancellations[a.id] == 1 }
    XCTAssertTrue(cancelled)
    // stop clears configuration before it waits for the deliberately slow teardown.
    var stopRequested = false
    let stop = Task {
      stopRequested = true
      await scheduler.stop()
    }
    let stopping = await eventually { stopRequested }
    XCTAssertTrue(stopping)
    await collector.finish(a.id)
    await refresh.value
    await stop.value
    await scheduler.refresh(accountID: a.id)
    let starts = await collector.starts
    let counts = await recorder.counts
    let active = await collector.active
    XCTAssertEqual(starts[a.id], 1)
    XCTAssertTrue(counts.isEmpty)
    XCTAssertEqual(active[a.id], 0)
  }
  func testStartDuringRefreshDrainsOldFetchAndUsesNewConfiguration() async {
    var a = account(.openai)
    let collector = ControlledCollector()
    let oldRecorder = ResultRecorder()
    let newRecorder = ResultRecorder()
    let scheduler = Scheduler(codex: collector, claude: collector)
    await scheduler.start(accounts: [a], interval: 600) { await oldRecorder.record($0, $1) }
    let started = await eventually { await collector.starts[a.id] == 1 }
    XCTAssertTrue(started)
    let refresh = Task { await scheduler.refresh(accountID: a.id) }
    let cancelled = await eventually { await collector.cancellations[a.id] == 1 }
    XCTAssertTrue(cancelled)
    a.name = "Reconfigured"
    await scheduler.start(accounts: [a], interval: 3000) { await newRecorder.record($0, $1) }
    let before = await collector.starts[a.id]
    XCTAssertEqual(before, 1)
    await collector.finish(a.id)
    await refresh.value
    let restarted = await eventually { await collector.starts[a.id] == 2 }
    XCTAssertTrue(restarted)
    await collector.finish(a.id)
    let delivered = await eventually { await newRecorder.counts[a.id] == 1 }
    XCTAssertTrue(delivered)
    await scheduler.stop()
    let old = await oldRecorder.counts
    let peak = await collector.peak[a.id]
    XCTAssertTrue(old.isEmpty)
    XCTAssertEqual(peak, 1)
  }
  func testRateLimitReleaseUsesLaterOfRetryAfterAndBackoff() {
    XCTAssertEqual(
      Scheduler.rateLimitRelease(retryAt: now.addingTimeInterval(5000), backoff: 1200, now: now),
      now.addingTimeInterval(5000))
    XCTAssertEqual(
      Scheduler.rateLimitRelease(retryAt: now.addingTimeInterval(60), backoff: 1200, now: now),
      now.addingTimeInterval(1200))
    XCTAssertEqual(
      Scheduler.rateLimitRelease(retryAt: nil, backoff: 1200, now: now),
      now.addingTimeInterval(1200))
  }
  func testSchedulerReportsReleaseAndWaitsForItAcrossRefreshAndRestart() async {
    let a = account()
    let retryAt = now.addingTimeInterval(5000)
    let collector = CountingCollector(.failure(CollectError(.rateLimited, retryAt: retryAt)))
    let recorder = ErrorRecorder()
    let scheduler = Scheduler(codex: collector, claude: collector, clock: FixedClock(date: now))
    await scheduler.start(accounts: [a], interval: 600) { await recorder.record($1) }
    let delivered = await eventually { await recorder.errors.count == 1 }
    XCTAssertTrue(delivered)
    let errors = await recorder.errors
    XCTAssertEqual(errors.first?.retryAt, retryAt)
    // A manual refresh inside the same scheduler waits for the release time.
    await scheduler.refresh(accountID: a.id)
    try? await Task.sleep(for: .milliseconds(50))
    var count = await collector.count
    XCTAssertEqual(count, 1)
    // A restarted scheduler given the persisted release time does not fetch either.
    let restarted = Scheduler(codex: collector, claude: collector, clock: FixedClock(date: now))
    await restarted.start(accounts: [a], interval: 600, holds: [a.id: retryAt]) { _, _ in }
    try? await Task.sleep(for: .milliseconds(50))
    count = await collector.count
    XCTAssertEqual(count, 1)
    await restarted.stop()
    // An expired release time fetches immediately.
    let expired = Scheduler(codex: collector, claude: collector, clock: FixedClock(date: now))
    await expired.start(accounts: [a], interval: 600, holds: [a.id: now.addingTimeInterval(-1)]) {
      _, _ in
    }
    let fetched = await eventually { await collector.count == 2 }
    XCTAssertTrue(fetched)
    await expired.stop()
    await scheduler.stop()
  }
  func testRefreshDuringRateLimitedFetchWaitsForItsRelease() async {
    let a = account()
    let retryAt = now.addingTimeInterval(5000)
    let collector = GatedRateLimitCollector(retryAt: retryAt)
    let recorder = ErrorRecorder()
    let scheduler = Scheduler(codex: collector, claude: collector, clock: FixedClock(date: now))
    await scheduler.start(accounts: [a], interval: 600) { await recorder.record($1) }
    let started = await eventually { await collector.waiting }
    XCTAssertTrue(started)
    // The refresh cancels the held fetch; its rate limit must still be reported and honored.
    let refresh = Task { await scheduler.refresh(accountID: a.id) }
    let cancelled = await eventually { await collector.cancelled }
    XCTAssertTrue(cancelled)
    await collector.open()
    await refresh.value
    let delivered = await eventually { await recorder.errors.count == 1 }
    XCTAssertTrue(delivered)
    try? await Task.sleep(for: .milliseconds(50))
    let fetches = await collector.fetches
    let errors = await recorder.errors
    XCTAssertEqual(fetches, 1)
    XCTAssertEqual(errors.first?.retryAt, retryAt)
    await scheduler.stop()
  }
  func testWaitingAccountRereadsAReleaseExtendedWhileItSlept() async {
    let first = now.addingTimeInterval(100)
    let extended = now.addingTimeInterval(5000)
    let waiting = account(.anthropic)
    let sibling = Account(name: "Sibling", provider: .anthropic, configDir: "/tmp/fake-sibling")
    let waitingCollector = CountingCollector(.success(CollectedUsage(snapshot())))
    let siblingCollector = GatedRateLimitCollector(retryAt: extended)
    let claude = RoutingCollector([waiting.id: waitingCollector, sibling.id: siblingCollector])
    let time = ManualTime(now)
    let recorder = ErrorRecorder()
    let scheduler = Scheduler(
      codex: claude, claude: claude, clock: time, pause: { try await time.pause($0) })
    await scheduler.start(accounts: [waiting, sibling], interval: 600, holds: [waiting.id: first]) {
      await recorder.record($1)
    }
    // The waiting account sleeps until `first`; the sibling's fetch is already in flight.
    let ready = await eventually { await siblingCollector.waiting && time.sleeping == 1 }
    XCTAssertTrue(ready)
    await siblingCollector.open()
    let limited = await eventually { await recorder.errors.count == 1 }
    XCTAssertTrue(limited)
    time.advance(to: first)
    // Let the woken account act; a re-read sleeps again, a missing re-read fetches now.
    try? await Task.sleep(for: .milliseconds(50))
    let resleeps = await eventually { time.sleeping == 2 }
    XCTAssertTrue(resleeps, "Both accounts sleep until the extended release")
    var fetches = await waitingCollector.count
    XCTAssertEqual(fetches, 0, "No request at the first release time")
    time.advance(to: extended)
    let resumed = await eventually { await waitingCollector.count == 1 }
    XCTAssertTrue(resumed, "The request goes out at the extended release time")
    fetches = await waitingCollector.count
    XCTAssertEqual(fetches, 1)
    await scheduler.stop()
  }
  func testClaudeRateLimitHoldsEveryClaudeAccountButNotCodex() async {
    let limited = account(.anthropic)
    let other = Account(name: "Other", provider: .anthropic, configDir: "/tmp/fake-deltavee-other")
    let codex = account(.openai)
    let retryAt = now.addingTimeInterval(5000)
    let limitedCollector = CountingCollector(.failure(CollectError(.rateLimited, retryAt: retryAt)))
    let claude = RoutingCollector([limited.id: limitedCollector])
    let codexCollector = CountingCollector(.success(CollectedUsage(snapshot())))
    let recorder = ErrorRecorder()
    let scheduler = Scheduler(codex: codexCollector, claude: claude, clock: FixedClock(date: now))
    await scheduler.start(accounts: [limited, other, codex], interval: 600) {
      await recorder.record($1)
    }
    let limitedOnce = await eventually { await recorder.errors.count == 1 }
    XCTAssertTrue(limitedOnce)
    let codexOnce = await eventually { await codexCollector.count == 1 }
    XCTAssertTrue(codexOnce)
    let otherBefore = await claude.count(other.id)
    await scheduler.refresh(accountID: other.id)
    await scheduler.refresh(accountID: codex.id)
    let codexAgain = await eventually { await codexCollector.count == 2 }
    XCTAssertTrue(codexAgain)
    try? await Task.sleep(for: .milliseconds(50))
    let otherAfter = await claude.count(other.id)
    XCTAssertEqual(otherAfter, otherBefore, "Another Claude account waits for the same release")
    await scheduler.stop()
  }
  func testSchedulerUsesBackoffAsReleaseWithoutRetryAfter() async {
    let a = account()
    let collector = CountingCollector(.failure(CollectError(.rateLimited)))
    let recorder = ErrorRecorder()
    let scheduler = Scheduler(codex: collector, claude: collector, clock: FixedClock(date: now))
    await scheduler.start(accounts: [a], interval: 600) { await recorder.record($1) }
    let delivered = await eventually { await recorder.errors.count == 1 }
    XCTAssertTrue(delivered)
    await scheduler.stop()
    let errors = await recorder.errors
    XCTAssertEqual(errors.first?.retryAt, now.addingTimeInterval(1200))
  }
  func testIndependentSchedulerAccountsAndFailureBackoff() async {
    let first = account(.openai)
    let second = account(.anthropic)
    let scheduler = Scheduler(
      codex: FixedCollector(result: .failure(CollectError(.schema))),
      claude: FixedCollector(result: .success(CollectedUsage(snapshot()))))
    let recorder = ResultRecorder()
    await scheduler.start(accounts: [first, second], interval: 600) { account, result in
      await recorder.record(account, result)
    }
    for _ in 0..<100 {
      if await recorder.values.count == 2 { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    await scheduler.stop()
    let values = await recorder.values
    XCTAssertEqual(values[first.id], false)
    XCTAssertEqual(values[second.id], true)
    XCTAssertEqual(Scheduler.delay(interval: 600, failures: 0), 600)
    XCTAssertEqual(Scheduler.delay(interval: 600, failures: 1), 1200)
    XCTAssertEqual(Scheduler.delay(interval: 600, failures: 20), 1800)
  }
  func testBackoffNeverShortensLongPollingInterval() {
    for failures in [0, 1, 2, 20] {
      XCTAssertEqual(Scheduler.delay(interval: 3000, failures: failures), 3000)
    }
  }
}
