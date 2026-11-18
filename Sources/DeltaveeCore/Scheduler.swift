import Foundation

public actor Scheduler {
  private struct PollingTask {
    let token: UUID
    let task: Task<Void, Never>
  }
  private var tasks: [UUID: PollingTask] = [:]
  private var accounts: [UUID: Account] = [:]
  /// Rate-limit release times; no fetch starts for an account before its entry.
  private var holds: [UUID: Date] = [:]
  private var interval: Double = 600
  private var onResult: (@Sendable (Account, Result<CollectedUsage, CollectError>) async -> Void)?
  private let codex: any Collector
  private let claude: any Collector
  private let clock: any UsageClock
  public init(codex: any Collector, claude: any Collector, clock: any UsageClock = SystemClock()) {
    self.codex = codex
    self.claude = claude
    self.clock = clock
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
  private func setHold(_ date: Date?, for id: UUID) { holds[id] = date }
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
        // A refresh or restart never fetches before an active rate-limit release time.
        if let release = hold(for: account.id) {
          let wait = release.timeIntervalSince(clock.now())
          if wait > 0 {
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
          }
        }
        var result = await collector.fetch(account)
        guard !Task.isCancelled else { return }
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
          setHold(release, for: account.id)
          delay = release.timeIntervalSince(now)
        } else {
          setHold(nil, for: account.id)
        }
        await onResult(account, result)
        do {
          try await Task.sleep(for: .seconds(delay))
        } catch { return }
      }
    }
    tasks[account.id] = PollingTask(token: token, task: task)
  }
}
