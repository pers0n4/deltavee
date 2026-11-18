import Foundation
import XCTest

@testable import DeltaveeCore

// `lock` protects the date and sleeper continuations; continuations resume outside the lock.
private final class ManualUpdateClock: UpdateClock, @unchecked Sendable {
  private struct Sleeper {
    let id: UUID
    let deadline: Date
    let continuation: CheckedContinuation<Void, any Error>
  }
  private let lock = NSLock()
  private var date: Date
  private var sleepers: [Sleeper] = []
  init(_ date: Date) { self.date = date }
  func now() -> Date { lock.withLock { date } }
  var deadlines: [Date] { lock.withLock { sleepers.map(\.deadline).sorted() } }
  func sleep(until deadline: Date) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let immediate: Result<Void, any Error>? = lock.withLock {
          if Task.isCancelled { return .failure(CancellationError()) }
          if deadline <= date { return .success(()) }
          sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return nil
        }
        if let immediate { continuation.resume(with: immediate) }
      }
    } onCancel: {
      let cancelled: Sleeper? = self.lock.withLock {
        guard let index = self.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return self.sleepers.remove(at: index)
      }
      cancelled?.continuation.resume(throwing: CancellationError())
    }
  }
  func advance(by seconds: TimeInterval) {
    let ready: [Sleeper] = lock.withLock {
      date = date.addingTimeInterval(seconds)
      let ready = sleepers.filter { $0.deadline <= date }
      sleepers.removeAll { $0.deadline <= date }
      return ready
    }
    for sleeper in ready { sleeper.continuation.resume() }
  }
}

private actor ScheduledReleaseHTTP: UsageHTTPTransport {
  private let responses: [Result<HTTPResult, URLError>]
  private(set) var count = 0
  init(_ responses: [HTTPResult]) { self.responses = responses.map { .success($0) } }
  init(results: [Result<HTTPResult, URLError>]) { responses = results }
  func send(_ request: URLRequest) async throws -> HTTPResult {
    let index = count
    count += 1
    return try responses[min(index, responses.count - 1)].get()
  }
}

private actor BlockedReleaseHTTP: UsageHTTPTransport {
  private(set) var count = 0
  private var pending: CheckedContinuation<HTTPResult, any Error>?
  private var finished: HTTPResult?
  func send(_ request: URLRequest) async throws -> HTTPResult {
    count += 1
    if let finished { return finished }
    guard pending == nil else { return HTTPResult(status: 500, body: Data()) }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          pending = continuation
        }
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }
  private func cancel() {
    pending?.resume(throwing: CancellationError())
    pending = nil
  }
  func finish(_ response: HTTPResult) {
    finished = response
    pending?.resume(returning: response)
    pending = nil
  }
}

// `lock` guards entries because logs are written by background tasks.
private final class RecordingUpdateLog: UpdateLogging, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [UpdateLogEntry] = []
  var entries: [UpdateLogEntry] { lock.withLock { stored } }
  func append(_ entry: UpdateLogEntry) { lock.withLock { stored.append(entry) } }
}

final class UpdateCheckerTests: CoreTestCase {
  func testStartupAndSuccessScheduleOnlyTheNextDailyRun() async throws {
    let clock = ManualUpdateClock(now)
    let http = ScheduledReleaseHTTP([release()])
    let checker = makeChecker(http, clock: clock)
    let before = await http.count
    XCTAssertEqual(before, 0, "Constructing a checker must not start network I/O")
    await checker.start()
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(86_400)] }
    XCTAssertEqual(UpdateChecker.dailyInterval, 86_400)
    clock.advance(by: 86_399)
    let early = await http.count
    XCTAssertEqual(early, 1)
    XCTAssertLessThan(86_399, UpdateChecker.dailyInterval)
    clock.advance(by: 1)
    try await eventually { await http.count == 2 }
    await checker.stop()
    XCTAssertTrue(clock.deadlines.isEmpty)
  }

  func testTransientFailuresCapAtThreeAutomaticAttemptsThenWaitForTheDailyCycle() async throws {
    let clock = ManualUpdateClock(now)
    let http = ScheduledReleaseHTTP(results: [
      .failure(URLError(.notConnectedToInternet)),
      .success(HTTPResult(status: 200, body: Data("{}".utf8))),
      .success(HTTPResult(status: 429, body: Data())),
      .success(release()),
    ])
    let log = RecordingUpdateLog()
    let checker = makeChecker(http, clock: clock, log: log)
    await checker.start()
    for attempt in 1...3 {
      let next = attempt < 3 ? TimeInterval(attempt * 1800) : 86_400
      try await eventually { clock.deadlines == [self.now.addingTimeInterval(next)] }
      let count = await http.count
      XCTAssertEqual(count, attempt)
      if attempt < 3 { clock.advance(by: 1800) }
    }
    XCTAssertEqual(UpdateChecker.maxAutomaticAttempts, 3)
    clock.advance(by: 86_400 - 3600 - 1)
    let capped = await http.count
    XCTAssertEqual(capped, 3)
    clock.advance(by: 1)
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(86_400 * 2)] }
    let nextCycle = await http.count
    XCTAssertEqual(nextCycle, 4)
    await checker.stop()
    XCTAssertEqual(log.entries.filter { $0.event == .started }.count, 4)
    XCTAssertEqual(log.entries.filter { $0.event == .finished }.count, 4)
    XCTAssertTrue(log.entries.allSatisfy { $0.trigger == .automatic })
  }

  func testUnavailableConfigurationNeverSendsHTTPAndUsesTheDailyDeadline() async throws {
    let clock = ManualUpdateClock(now)
    let http = ScheduledReleaseHTTP([release()])
    let checker = UpdateChecker(
      configuration: .failure(.configuration), transport: http, clock: clock,
      log: RecordingUpdateLog())
    await checker.start()
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(86_400)] }
    let state = await checker.state
    XCTAssertEqual(state.status, .unavailable(.configuration))
    let manual = await checker.checkNow()
    XCTAssertEqual(manual, .unavailable(.configuration))
    let count = await http.count
    XCTAssertEqual(count, 0)
    await checker.stop()
  }

  func testPermanentAndNoReleaseFailuresWaitUntilTheNextDay() async throws {
    for status in [400, 403, 404] {
      let clock = ManualUpdateClock(now)
      let http = ScheduledReleaseHTTP([HTTPResult(status: status, body: Data())])
      let checker = makeChecker(http, clock: clock)
      await checker.start()
      try await eventually { clock.deadlines == [self.now.addingTimeInterval(86_400)] }
      clock.advance(by: 1800)
      let count = await http.count
      XCTAssertEqual(count, 1, "HTTP \(status) must not enter the short retry loop")
      let state = await checker.state
      guard case .unavailable = state.status else { return XCTFail("Expected unavailable") }
      XCTAssertNil(state.lastSuccessfulCheck)
      await checker.stop()
    }
  }

  func testManualErrorsAreNotCachedAndSuccessReplacesTheRememberedRelease() async throws {
    let clock = ManualUpdateClock(now)
    let http = ScheduledReleaseHTTP([
      HTTPResult(status: 500, body: Data()), HTTPResult(status: 200, body: Data("{}".utf8)),
      release(tag: "v0.2.0"), HTTPResult(status: 404, body: Data()), release(tag: "v0.1.0"),
    ])
    let checker = makeChecker(http, clock: clock)
    await awaitResult(checker, expected: .unavailable(.http(500)))
    let malformed = await checker.checkNow()
    XCTAssertEqual(malformed, .unavailable(.invalidResponse))
    var state = await checker.state
    XCTAssertNil(state.lastSuccessfulCheck)
    guard case .available = await checker.checkNow() else { return XCTFail("Expected update") }
    state = await checker.state
    XCTAssertEqual(state.availableRelease?.version.description, "0.2.0")
    XCTAssertEqual(state.lastSuccessfulCheck, now)
    _ = await checker.checkNow()
    state = await checker.state
    XCTAssertEqual(state.status, .unavailable(.noRelease))
    XCTAssertEqual(
      state.availableRelease?.version.description, "0.2.0", "Only successes replace the cache")
    _ = await checker.checkNow()
    state = await checker.state
    XCTAssertNil(state.availableRelease, "A successful current response clears the prior release")
    let count = await http.count
    XCTAssertEqual(count, 5, "Every manual retry reaches the server after an error")
    await checker.stop()
  }

  func testManualFailuresDoNotResetTheAutomaticRetryDeadlineOrBudget() async throws {
    let clock = ManualUpdateClock(now)
    let http = ScheduledReleaseHTTP([HTTPResult(status: 503, body: Data())])
    let checker = makeChecker(http, clock: clock)
    await checker.start()
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(1800)] }
    clock.advance(by: 60)
    _ = await checker.checkNow()
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(1800)] }
    clock.advance(by: 1740)
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(3600)] }
    _ = await checker.checkNow()
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(3600)] }
    clock.advance(by: 1800)
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(86_400)] }
    let count = await http.count
    XCTAssertEqual(count, 5, "Three automatic attempts and two manual attempts")
    await checker.stop()
  }

  func testSuccessfulManualCheckResetsDailyDeadlineWithoutStartingAnotherAutomaticRun() async throws
  {
    let clock = ManualUpdateClock(now)
    let http = ScheduledReleaseHTTP([HTTPResult(status: 500, body: Data()), release()])
    let checker = makeChecker(http, clock: clock)
    await checker.start()
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(1800)] }
    clock.advance(by: 60)
    _ = await checker.checkNow()
    try await eventually { clock.deadlines == [self.now.addingTimeInterval(60 + 86_400)] }
    clock.advance(by: 1740)
    let count = await http.count
    XCTAssertEqual(count, 2, "The superseded retry must be cancelled")
    await checker.stop()
  }

  func testManualAndAutomaticRequestsShareOneFlightAndOneLogPair() async throws {
    let clock = ManualUpdateClock(now)
    let http = BlockedReleaseHTTP()
    let log = RecordingUpdateLog()
    let checker = makeChecker(http, clock: clock, log: log)
    await checker.start()
    try await eventually { await http.count == 1 }
    let manual = Task { await checker.checkNow() }
    // Let the manual actor call join the already-blocked request before completing its HTTP response.
    for _ in 0..<100 { await Task.yield() }
    await http.finish(release(tag: "v0.2.0"))
    guard case .available = await manual.value else { return XCTFail("Expected shared update") }
    let count = await http.count
    XCTAssertEqual(count, 1)
    XCTAssertEqual(log.entries.map(\.event), [.started, .finished])
    XCTAssertEqual(log.entries.first?.runID, log.entries.last?.runID)
    await checker.stop()
  }

  func testStopCancelsInFlightNetworkAndEmitsOnlyACancelledLogFinish() async throws {
    let clock = ManualUpdateClock(now)
    let http = BlockedReleaseHTTP()
    let log = RecordingUpdateLog()
    let checker = makeChecker(http, clock: clock, log: log)
    await checker.start()
    try await eventually { await http.count == 1 }
    await checker.stop()
    XCTAssertTrue(clock.deadlines.isEmpty)
    XCTAssertEqual(log.entries.map(\.event), [.started, .finished])
    XCTAssertEqual(log.entries.last?.outcome, .cancelled)
    XCTAssertNil(log.entries.last?.failure)
    clock.advance(by: 172_800)
    let count = await http.count
    XCTAssertEqual(count, 1)
  }

  func testLogFileIsMode600RepairsExistingPermissionsAndRotatesWithinTheCap() throws {
    let directory = try temporaryDirectory().appendingPathComponent("app")
    let log = UpdateLog(directory: directory, maxBytes: 1024)
    let entry = UpdateLogEntry(event: .started, time: now, runID: UUID(), trigger: .automatic)
    log.append(entry)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.file.path)
    let line = try Data(contentsOf: log.file)
    XCTAssertLessThan(line.count, log.maxBytes)
    let repeats = log.maxBytes / line.count + 2
    XCTAssertGreaterThan(
      line.count * repeats, log.maxBytes, "The fixture must cross the rotation cap")
    for _ in 0..<repeats { log.append(entry) }
    for file in [log.file, log.file.appendingPathExtension("1")] {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
      let data = try Data(contentsOf: file)
      XCTAssertLessThanOrEqual(data.count, log.maxBytes)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      for line in data.split(separator: 10) {
        XCTAssertEqual(try decoder.decode(UpdateLogEntry.self, from: Data(line)), entry)
      }
    }
    let text = try String(contentsOf: log.file, encoding: .utf8)
    XCTAssertFalse(text.contains("Authorization"))
    XCTAssertFalse(text.contains("html_url"))
    XCTAssertFalse(text.contains("accessToken"))
  }

  private func makeChecker(
    _ http: any UsageHTTPTransport, clock: any UpdateClock,
    log: RecordingUpdateLog = RecordingUpdateLog()
  ) -> UpdateChecker {
    UpdateChecker(
      configuration: .success(
        try! UpdateConfiguration(version: "0.1.0", repository: "pers0n4/deltavee")),
      transport: http, clock: clock, log: log)
  }
  private func release(tag: String = "v0.1.0") -> HTTPResult {
    HTTPResult(
      status: 200,
      body: Data(
        "{\"tag_name\":\"\(tag)\",\"html_url\":\"https://github.com/pers0n4/deltavee/releases/tag/\(tag)\",\"draft\":false,\"prerelease\":false}"
          .utf8))
  }
  private enum WaitError: Error { case didNotSettle }
  private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<10_000 {
      if await condition() { return }
      await Task.yield()
    }
    XCTFail("The injected-clock operation did not settle")
    throw WaitError.didNotSettle
  }
  private func awaitResult(_ checker: UpdateChecker, expected: UpdateStatus) async {
    let result = await checker.checkNow()
    XCTAssertEqual(result, expected)
  }
}
