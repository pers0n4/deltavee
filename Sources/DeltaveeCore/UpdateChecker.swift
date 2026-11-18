import Foundation

public protocol UpdateClock: UsageClock {
  func sleep(until deadline: Date) async throws
}
public struct SystemUpdateClock: UpdateClock {
  public init() {}
  public func now() -> Date { Date() }
  public func sleep(until deadline: Date) async throws {
    try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
  }
}

/// Owns the single in-flight request and the independent update-check schedule, never usage polling.
public actor UpdateChecker {
  public static let dailyInterval: TimeInterval = 86_400
  public static let retryInterval: TimeInterval = 1800
  /// Total automatic attempts per daily cycle: the initial check and at most two retries.
  public static let maxAutomaticAttempts = 3
  public nonisolated let updates: AsyncStream<UpdateState>
  public private(set) var state: UpdateState
  private let continuation: AsyncStream<UpdateState>.Continuation
  private let client: GitHubReleaseClient
  private let clock: any UpdateClock
  private let log: any UpdateLogging
  private struct Flight {
    let id: UUID
    let task: Task<UpdateStatus, Never>
  }
  private var flight: Flight?
  private var timer: Task<Void, Never>?
  private var timerID = UUID()
  private var running = false
  private var stopped = false
  private var cycleStart: Date?
  private var automaticAttempts = 0
  private var nextAutomaticCheck: Date?

  public init(
    configuration: Result<UpdateConfiguration, UpdateFailure>,
    transport: any UsageHTTPTransport = BoundedUpdateHTTPTransport(),
    clock: any UpdateClock = SystemUpdateClock(), log: any UpdateLogging = UpdateLog()
  ) {
    client = GitHubReleaseClient(configuration: configuration, transport: transport)
    self.clock = clock
    self.log = log
    let stream = AsyncStream.makeStream(of: UpdateState.self, bufferingPolicy: .bufferingNewest(1))
    updates = stream.stream
    continuation = stream.continuation
    if case .failure(let failure) = configuration {
      state = UpdateState(status: .unavailable(failure))
    } else {
      state = UpdateState()
    }
    continuation.yield(state)
  }

  public func start() {
    guard !running, !stopped else { return }
    running = true
    let now = clock.now()
    cycleStart = now
    nextAutomaticCheck = now
    scheduleNext()
  }

  /// Manual errors never enter a cache or consume the automatic retry budget.
  public func checkNow() async -> UpdateStatus {
    guard !stopped else { return .unavailable(.cancelled) }
    return await beginCheck(trigger: .manual).value
  }

  public func stop() async {
    stopped = true
    running = false
    let timer = self.timer
    self.timer = nil
    timer?.cancel()
    let request = flight?.task
    request?.cancel()
    _ = await request?.value
    await timer?.value
    continuation.finish()
  }

  private func beginCheck(trigger: UpdateLogEntry.Trigger) -> Task<UpdateStatus, Never> {
    if let flight { return flight.task }
    let started = clock.now()
    if trigger == .automatic {
      if cycleStart == nil || started >= cycleStart!.addingTimeInterval(Self.dailyInterval) {
        cycleStart = started
        automaticAttempts = 0
      }
      automaticAttempts += 1
    }
    let id = UUID()
    state = UpdateState(
      status: .checking, availableRelease: state.availableRelease,
      lastSuccessfulCheck: state.lastSuccessfulCheck)
    continuation.yield(state)
    log.append(UpdateLogEntry(event: .started, time: started, runID: id, trigger: trigger))
    let client = client
    let task = Task {
      let result = await client.check()
      self.finish(id: id, trigger: trigger, started: started, result: result)
      return result
    }
    flight = Flight(id: id, task: task)
    return task
  }

  private func finish(
    id: UUID, trigger: UpdateLogEntry.Trigger, started: Date, result: UpdateStatus
  ) {
    guard flight?.id == id else { return }
    flight = nil
    let finished = clock.now()
    let outcome: UpdateLogEntry.Outcome
    let failure: UpdateFailure?
    if stopped || result == .unavailable(.cancelled) {
      outcome = .cancelled
      failure = nil
    } else {
      switch result {
      case .current:
        outcome = .current
        failure = nil
      case .available:
        outcome = .available
        failure = nil
      case .unavailable(let error):
        outcome = .unavailable
        failure = error
      case .idle, .checking: preconditionFailure("A release check must have a final status")
      }
    }
    log.append(
      UpdateLogEntry(
        event: .finished, time: finished, runID: id, trigger: trigger, outcome: outcome,
        failure: failure,
        durationSeconds: (max(0, finished.timeIntervalSince(started)) * 1000).rounded() / 1000))
    guard !stopped else { return }
    let succeeded: Bool
    switch result {
    case .current:
      state = UpdateState(status: result, lastSuccessfulCheck: finished)
      succeeded = true
    case .available:
      state = UpdateState(status: result, lastSuccessfulCheck: finished)
      succeeded = true
    case .unavailable:
      state = UpdateState(
        status: result, availableRelease: state.availableRelease,
        lastSuccessfulCheck: state.lastSuccessfulCheck)
      succeeded = false
    case .idle, .checking: preconditionFailure("A release check must have a final status")
    }
    continuation.yield(state)
    guard running else { return }
    if trigger == .manual {
      if succeeded {
        cycleStart = finished
        automaticAttempts = 0
        nextAutomaticCheck = finished.addingTimeInterval(Self.dailyInterval)
      }
    } else {
      let daily = (cycleStart ?? started).addingTimeInterval(Self.dailyInterval)
      if case .unavailable(let failure) = result, failure.isTransient,
        automaticAttempts < Self.maxAutomaticAttempts
      {
        nextAutomaticCheck = min(daily, finished.addingTimeInterval(Self.retryInterval))
      } else {
        nextAutomaticCheck = daily
      }
    }
    scheduleNext()
  }

  private func scheduleNext() {
    timer?.cancel()
    guard running, let deadline = nextAutomaticCheck else { return }
    let id = UUID()
    timerID = id
    let clock = clock
    timer = Task {
      do { try await clock.sleep(until: deadline) } catch { return }
      guard !Task.isCancelled else { return }
      await self.runAutomaticCheck(id: id)
    }
  }
  private func runAutomaticCheck(id: UUID) async {
    guard running, !stopped, timerID == id else { return }
    timer = nil
    _ = await beginCheck(trigger: .automatic).value
  }
}
