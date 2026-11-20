import DeltaveeCore
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
  var document = AccountDocument()
  var states: [UUID: AccountState] = [:]
  var pendingIdentities: [UUID: String] = [:]
  var refreshingAccountIDs: Set<UUID> = []
  var notice: String?
  var now = Date()
  var loginEnabled = SMAppService.mainApp.status == .enabled
  /// Registered but waiting for the user's approval in System Settings → Login Items.
  var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
  let updates: UpdateModel
  @ObservationIgnored private let accountStore: AccountStore
  @ObservationIgnored private let snapshotStore: SnapshotStore
  @ObservationIgnored private let rateLimitStore: RateLimitStore
  /// Per-account rate-limit release times, kept across scheduler restarts and app relaunches.
  private(set) var rateLimitHolds: [UUID: Date] = [:]
  @ObservationIgnored private let makeScheduler: (DeltaveeCore.Settings) -> Scheduler
  @ObservationIgnored private var scheduler: Scheduler?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var configurationTask: Task<Void, Never>?
  @ObservationIgnored private var accountStoreWritable = true
  /// Wait between a system wake and its refresh so the network can reconnect before the first fetch.
  /// Chosen delay, not a measured network-recovery bound.
  static let wakeRefreshDelay: Duration = .seconds(5)
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var wakeTask: Task<Void, Never>?

  init(
    accountStore: AccountStore = AccountStore(), snapshotStore: SnapshotStore = SnapshotStore(),
    makeScheduler: @escaping (DeltaveeCore.Settings) -> Scheduler = { settings in
      Scheduler(
        codex: CodexAppServerCollector(executable: {
          Executables.resolveCodex(configured: settings.codexPath)
        }),
        claude: ClaudeUsageCollector(
          source: settings.claudeSource,
          claudePath: { Executables.resolveClaude(configured: settings.claudePath) }))
    },
    clock: any Clock<Duration> = ContinuousClock(), updates: UpdateModel? = nil
  ) {
    self.clock = clock
    self.updates = updates ?? UpdateModel()
    self.accountStore = accountStore
    self.snapshotStore = snapshotStore
    rateLimitStore = RateLimitStore(directory: snapshotStore.directory)
    self.makeScheduler = makeScheduler
    do { document = try accountStore.load() } catch {
      let file = accountStore.directory.appendingPathComponent("accounts.json")
      if FileManager.default.fileExists(atPath: file.path) {
        let backup = file.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        do { try FileManager.default.moveItem(at: file, to: backup) } catch {
          accountStoreWritable = false
        }
      }
      notice =
        accountStoreWritable
        ? "Account settings could not be read. The original was backed up; starting with no accounts."
        : "Account settings could not be backed up. Saving is disabled to protect the original."
    }
    do { states = try snapshotStore.load() } catch {
      notice = [notice, "Usage history could not be read and was reset."].compactMap { $0 }.joined(
        separator: "\n")
    }
    // An unreadable file only loses the wait; the next 429 records a fresh release time.
    rateLimitHolds = (try? rateLimitStore.load()) ?? [:]
  }
  func isRateLimitHeld(_ id: UUID, now: Date = Date()) -> Bool {
    guard let account = document.accounts.first(where: { $0.id == id }),
      usesRateLimitedSource(account, settings: document.settings)
    else { return false }
    return rateLimitHolds[id].map { $0 > now } ?? false
  }
  /// Only the Claude OAuth usage endpoint answers 429; statusline-only reads keep the hold for later.
  private func usesRateLimitedSource(_ account: Account, settings: DeltaveeCore.Settings) -> Bool {
    !(account.provider == .anthropic && settings.claudeSource == .statuslineOnly)
  }
  func tick() {
    now = Date()
  }
  /// After `wakeRefreshDelay`, restarts collection for every account and re-evaluates staleness.
  /// A later wake within the delay replaces the pending one. Fetch failures follow the scheduler's
  /// usual backoff, and rate-limit holds still apply.
  func systemDidWake() {
    wakeTask?.cancel()
    let clock = clock
    wakeTask = Task { [weak self] in
      do { try await Self.sleep(clock, for: Self.wakeRefreshDelay) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.refresh()
      self.tick()
    }
  }
  private static func sleep<C: Clock<Duration>>(_ clock: C, for duration: Duration) async throws {
    try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
  }
  func refresh() {
    generation = UUID()
    let current = generation
    let accounts = document.accounts
    let settings = document.settings
    let now = Date()
    rateLimitHolds = rateLimitHolds.filter { hold in
      hold.value > now && accounts.contains { $0.id == hold.key }
    }
    let holds = rateLimitHolds.filter { hold in
      accounts.contains { $0.id == hold.key && usesRateLimitedSource($0, settings: settings) }
    }
    // Held accounts fetch only after their release time, so they are not shown as refreshing.
    refreshingAccountIDs = Set(accounts.map(\.id).filter { !isRateLimitHeld($0, now: now) })
    configurationTask?.cancel()
    let previous = scheduler
    let next = makeScheduler(settings)
    scheduler = next
    configurationTask = Task { [weak self] in
      await previous?.stop()
      guard !Task.isCancelled else { return }
      await next.start(accounts: accounts, interval: settings.validInterval, holds: holds) {
        [weak self] account, result in
        await self?.receive(account: account, result: result, generation: current)
      }
    }
  }
  func refresh(accountID: UUID) {
    guard document.accounts.contains(where: { $0.id == accountID }),
      !refreshingAccountIDs.contains(accountID), !isRateLimitHeld(accountID)
    else { return }
    refreshingAccountIDs.insert(accountID)
    let current = generation
    let configuration = configurationTask
    Task { [weak self] in
      await configuration?.value
      guard let self, current == self.generation else { return }
      await self.scheduler?.refresh(accountID: accountID)
    }
  }
  private func receive(
    account: Account, result: Result<CollectedUsage, CollectError>, generation: UUID
  ) {
    guard generation == self.generation,
      let index = document.accounts.firstIndex(where: { $0.id == account.id })
    else { return }
    refreshingAccountIDs.remove(account.id)
    let candidate: QuotaSnapshot?
    switch result {
    case .success(let value): candidate = value.snapshot
    case .failure(let error): candidate = error.fallback
    }
    if usesRateLimitedSource(account, settings: document.settings) {
      if case .failure(let error) = result, error.kind == .rateLimited, let release = error.retryAt
      {
        rateLimitHolds[account.id] = release
      } else {
        rateLimitHolds.removeValue(forKey: account.id)
      }
    }
    let previous = states[account.id] ?? .neverFetched
    let updated = StateReducer.applying(result, to: previous, account: &document.accounts[index])
    if case .identityChanged = updated {
      // Keep the pending identity across failures that carry no fingerprint so acceptance stays possible.
      if let fingerprint = candidate?.identityFingerprint,
        fingerprint != document.accounts[index].identityFingerprint
      {
        pendingIdentities[account.id] = fingerprint
      }
    } else {
      pendingIdentities.removeValue(forKey: account.id)
    }
    states[account.id] = updated
    persist()
    tick()
  }
  func save(_ newDocument: AccountDocument) {
    var updated = newDocument
    updated.settings.intervalSeconds = updated.settings.validInterval
    for account in updated.accounts {
      if let previous = document.accounts.first(where: { $0.id == account.id }),
        let index = updated.accounts.firstIndex(where: { $0.id == account.id })
      {
        if previous.provider != account.provider
          || previous.expandedDirectory != account.expandedDirectory
        {
          states.removeValue(forKey: account.id)
          pendingIdentities.removeValue(forKey: account.id)
          // A different source has its own limit; the old release time no longer applies.
          rateLimitHolds.removeValue(forKey: account.id)
          updated.accounts[index].identityFingerprint = nil
        } else {
          updated.accounts[index].identityFingerprint = previous.identityFingerprint
        }
      }
    }
    let ids = Set(updated.accounts.map(\.id))
    states = states.filter { ids.contains($0.key) }
    pendingIdentities = pendingIdentities.filter { ids.contains($0.key) }
    rateLimitHolds = rateLimitHolds.filter { ids.contains($0.key) }
    // Settings apply live; display-only edits must not restart collection on every change.
    let restartCollection = CollectionInputs(updated) != CollectionInputs(document)
    document = updated
    persist()
    if restartCollection { refresh() }
    tick()
  }
  /// Values the scheduler and collectors read; account order, labels, and display settings are excluded.
  private struct CollectionInputs: Equatable {
    struct Source: Equatable {
      let id: UUID
      let provider: Provider
      let directory: String
    }
    let sources: [Source]
    let claudeSource: ClaudeSource
    let claudePath: String
    let codexPath: String
    let interval: Double
    init(_ document: AccountDocument) {
      sources = document.accounts
        .map { Source(id: $0.id, provider: $0.provider, directory: $0.expandedDirectory) }
        .sorted { $0.id.uuidString < $1.id.uuidString }
      claudeSource = document.settings.claudeSource
      claudePath = document.settings.claudePath
      codexPath = document.settings.codexPath
      interval = document.settings.validInterval
    }
  }
  func acceptIdentity(_ id: UUID) {
    guard let fingerprint = pendingIdentities[id],
      let index = document.accounts.firstIndex(where: { $0.id == id })
    else { return }
    states[id] = StateReducer.acceptIdentity(fingerprint, account: &document.accounts[index])
    pendingIdentities.removeValue(forKey: id)
    persist()
    refresh()
    tick()
  }
  private func persist() {
    do {
      if accountStoreWritable { try accountStore.save(document) }
      try snapshotStore.save(states)
      try rateLimitStore.save(rateLimitHolds)
    } catch { notice = "Could not save. Check permissions for the Application Support folder." }
  }
  func setLogin(_ enabled: Bool) {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      notice = "Launch at login is available from the signed app bundle."
      return
    }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refreshLoginStatus()
      if enabled && !loginEnabled && !loginNeedsApproval {
        notice = "Allow this app in System Settings → Login Items."
      }
    } catch { notice = "Could not update launch at login. Check System Settings → Login Items." }
  }
  /// Re-reads the login item status; approval can change in System Settings while the app runs.
  func refreshLoginStatus() {
    let status = SMAppService.mainApp.status
    loginEnabled = status == .enabled
    loginNeedsApproval = status == .requiresApproval
  }
}
