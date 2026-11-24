import Foundation

public actor Scheduler {
  private struct PollingTask {
    let token: UUID
    let task: Task<Void, Never>
  }
  private var tasks: [UUID: PollingTask] = [:]
  private var accounts: [UUID: Account] = [:]
  /// Rate-limit release times; no fetch starts for an account before its entry. A Claude rate limit
  /// holds every Claude account (see `ClaudeRateLimitStore`), and only time lifts a hold.
  private var holds: [UUID: Date] = [:]
  private var interval: Double = 600
  private var onResult: (@Sendable (Account, Result<CollectedUsage, CollectError>) async -> Void)?
  private let codex: any Collector
  private let claude: any Collector
  private let clock: any UsageClock
  /// Waits the given seconds; injected by tests together with `clock`.
  private let pause: @Sendable (TimeInterval) async throws -> Void
  public init(
    codex: any Collector, claude: any Collector, clock: any UsageClock = SystemClock(),
    pause: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) {
    self.codex = codex
    self.claude = claude
    self.clock = clock
    self.pause = pause
  }
  public func stop() async {
    accounts.removeAll()
    holds.removeAll()
    onResult = nil
    let pending = tasks.values.map(\.task)
    for task in pending { task.cancel() }
    for task in pending { await task.value }
  }
  public static func delay(interval: Double, failures: Int) -> Double {
    let base = interval.isFinite ? min(3599, max(30, interval)) : 600
    return failures == 0 ? base : max(base, min(1800, base * pow(2, Double(min(failures, 10)))))
  }
  /// Next allowed attempt after a rate limit: the later of the server's `Retry-After` and the backoff.
  public static func rateLimitRelease(retryAt: Date?, backoff: Double, now: Date) -> Date {
    max(now.addingTimeInterval(backoff), retryAt ?? .distantPast)
  }
  /// `holds` carries rate-limit release times persisted from earlier runs; past entries are ignored.
  public func start(
    accounts: [Account], interval: Double, holds: [UUID: Date] = [:],
    onResult: @escaping @Sendable (Account, Result<CollectedUsage, CollectError>) async -> Void
  ) {
    for entry in tasks.values { entry.task.cancel() }
    self.accounts = [:]
    self.interval = interval
    self.onResult = onResult
    let ids = Set(accounts.map(\.id))
    self.holds = holds.filter { ids.contains($0.key) }
    for account in accounts {
      self.accounts[account.id] = account
      schedule(account, interval: interval, onResult: onResult)
    }
  }
  public func refresh(accountID: UUID) async {
    guard let account = accounts[accountID], let onResult else { return }
    let previous = tasks[accountID]?.task
    schedule(account, interval: interval, onResult: onResult)
    await previous?.value
  }
  private func hold(for id: UUID) -> Date? { holds[id] }
  private func recordRateLimit(_ release: Date, for account: Account) {
    let held =
      account.provider == .anthropic
      ? Set(accounts.values.filter { $0.provider == .anthropic }.map(\.id)).union([account.id])
      : [account.id]
    for id in held { holds[id] = max(holds[id] ?? .distantPast, release) }
  }
  private func schedule(
    _ account: Account, interval: Double,
    onResult: @escaping @Sendable (Account, Result<CollectedUsage, CollectError>) async -> Void
  ) {
    let previous = tasks[account.id]?.task
    previous?.cancel()
    let token = UUID()
    let collector = account.provider == .openai ? codex : claude
    let clock = clock
    let task = Task {
      // Keep cancelled fetches (including process teardown) in the chain until they finish.
      await previous?.value
      defer {
        if tasks[account.id]?.token == token { tasks.removeValue(forKey: account.id) }
      }
      var failures = 0
      while !Task.isCancelled {
        // A refresh or restart never fetches before an active rate-limit release time. Another
        // Claude account's 429 can move the release later during the wait, so read it again after
        // every wake.
        while let release = hold(for: account.id), release > clock.now() {
          do { try await pause(release.timeIntervalSince(clock.now())) } catch { return }
        }
        var result = await collector.fetch(account)
        // A cancelled fetch's result is dropped, except a rate limit: the server counted that
        // request, so the release time must reach the next fetch and the caller.
        let cancelled = Task.isCancelled
        switch result {
        case .success: failures = 0
        case .failure: failures += 1
        }
        var delay = Self.delay(interval: interval, failures: failures)
        if case .failure(var error) = result, error.kind == .rateLimited {
          let now = clock.now()
          let release = Self.rateLimitRelease(retryAt: error.retryAt, backoff: delay, now: now)
          error.retryAt = release
          result = .failure(error)
          recordRateLimit(release, for: account)
          delay = release.timeIntervalSince(now)
        } else if cancelled {
          return
        }
        await onResult(account, result)
        if cancelled { return }
        do {
          try await pause(delay)
        } catch { return }
      }
    }
    tasks[account.id] = PollingTask(token: token, task: task)
  }
}
