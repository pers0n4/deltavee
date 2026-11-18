import XCTest

@testable import DeltaveeCore

private struct FixedCollector: Collector {
  let result: Result<CollectedUsage, CollectError>
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> { result }
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
