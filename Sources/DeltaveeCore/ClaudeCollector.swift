import Foundation

public struct OAuthCredential: Sendable {
  let accessToken: String
  public let expiresAt: Date
  /// How the CLI was run when it stored this login; a refresh run and `.claude.json` must match it.
  public let configDirVariable: ClaudeConfigDirVariable
  public init(accessToken: String, expiresAt: Date, configDirVariable: ClaudeConfigDirVariable) {
    self.accessToken = accessToken
    self.expiresAt = expiresAt
    self.configDirVariable = configDirVariable
  }
}
public protocol CredentialReading: Sendable {
  func read(configDir: String) async throws -> OAuthCredential
}
public struct ClaudeCredentialReader: CredentialReading {
  private let runner: any CommandRunning
  public init(runner: any CommandRunning = LiveCommandRunner()) { self.runner = runner }
  /// Reads each Keychain item the directory can have. When the default directory holds one from each
  /// way of running the CLI, the later expiry wins: it is the login the CLI refreshed most recently.
  public func read(configDir: String) async throws -> OAuthCredential {
    let variables = Paths.claudeConfigDirVariables(configDir: configDir)
    var latest: OAuthCredential?
    for variable in variables {
      let service = Paths.claudeService(configDir: configDir, variable: variable)
      guard
        let output = try? await runner.run(
          executable: "/usr/bin/security",
          arguments: ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"],
          environment: [:], timeout: 20), output.status == 0,
        let credential = try? Self.parse(output.data, configDirVariable: variable)
      else { continue }
      if latest.map({ credential.expiresAt > $0.expiresAt }) ?? true { latest = credential }
    }
    if let latest { return latest }
    // Both ways of running the CLI share this file, so it is attributed to the first one.
    guard
      let data = try? Data(
        contentsOf: URL(fileURLWithPath: Paths.absolute(configDir)).appendingPathComponent(
          ".credentials.json"))
    else { throw CollectError(.authRequired) }
    return try Self.parse(data, configDirVariable: variables[0])
  }
  /// `expiresAt` is epoch milliseconds: Claude Code stores `Date.now() + expires_in * 1000`.
  /// Verified 2026-11-15 against Claude Code 2.1.322.
  public static func parse(_ data: Data, configDirVariable: ClaudeConfigDirVariable) throws
    -> OAuthCredential
  {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let oauth = root["claudeAiOauth"] as? [String: Any],
      let token = oauth["accessToken"] as? String, !token.isEmpty,
      let expires = Parsing.epoch(oauth["expiresAt"])
    else { throw CollectError(.authRequired) }
    return OAuthCredential(
      accessToken: token,
      expiresAt: Date(timeIntervalSince1970: expires.timeIntervalSince1970 / 1000),
      configDirVariable: configDirVariable)
  }
}
public struct HTTPResult: Sendable {
  public var status: Int
  public var body: Data
  /// Raw `Retry-After` header value, when the server sent one.
  public var retryAfter: String?
  public init(status: Int, body: Data, retryAfter: String? = nil) {
    self.status = status
    self.body = body
    self.retryAfter = retryAfter
  }
}
public protocol UsageHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPResult
}
public struct EphemeralHTTPTransport: UsageHTTPTransport {
  public init() {}
  public func send(_ request: URLRequest) async throws -> HTTPResult {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(
      configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw CollectError(.transport) }
    return HTTPResult(
      status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After")
    )
  }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
public protocol ClaudeIdentityReading: Sendable {
  /// `variable` is the credential's; nil when no credential was read.
  func fingerprint(configDir: String, variable: ClaudeConfigDirVariable?) -> String?
}
public struct ClaudeIdentityReader: ClaudeIdentityReading {
  private let globalConfig: @Sendable (String, ClaudeConfigDirVariable) -> URL
  public init(
    globalConfig: @escaping @Sendable (String, ClaudeConfigDirVariable) -> URL = {
      Paths.claudeGlobalConfig(configDir: $0, variable: $1)
    }
  ) { self.globalConfig = globalConfig }
  /// Reads the `.claude.json` written alongside the credential's Keychain item. Without a credential,
  /// the most recently modified candidate stands for the login the CLI used last.
  public func fingerprint(configDir: String, variable: ClaudeConfigDirVariable?) -> String? {
    let candidates = (variable.map { [$0] } ?? Paths.claudeConfigDirVariables(configDir: configDir))
      .map { globalConfig(configDir, $0) }
    let modified = { (file: URL) in
      (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    guard
      let file = candidates.filter({ modified($0) != nil }).max(by: {
        modified($0)! < modified($1)!
      }),
      let data = try? Data(contentsOf: file),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let account = root["oauthAccount"] as? [String: Any],
      let identity = account["accountUuid"] as? String
    else { return nil }
    return Paths.fingerprint(identity)
  }
}
public protocol StatuslineReading: Sendable {
  func read(configDir: String, now: Date) -> QuotaSnapshot?
}
public struct StatuslineReader: StatuslineReading {
  private let root: URL
  public init(root: URL = Paths.applicationSupport) { self.root = root }
  public func read(configDir: String, now: Date) -> QuotaSnapshot? {
    let file = Paths.statuslineFile(configDir: configDir, root: root)
    guard let data = try? Data(contentsOf: file),
      let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return try? Self.parse(data, modifiedAt: modified, now: now)
  }
  public static func parse(_ data: Data, modifiedAt: Date, now: Date) throws -> QuotaSnapshot {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let observed = Parsing.epoch(root["observedAt"]),
      let limits = root["rateLimits"] as? [String: Any]
    else { throw CollectError(.schema) }
    var weekly: (used: Double, resetsAt: Date?)?
    if let raw = limits["seven_day"], !(raw is NSNull) {
      guard let value = raw as? [String: Any], let used = Parsing.percent(value["used_percentage"])
      else { throw CollectError(.schema) }
      weekly = (used, Parsing.epoch(value["resets_at"]))
    }
    // Assets/claude-statusline-capture.sh writes `observedAt` (`time.time()`) and the file together.
    // When they differ after copying, editing, or clock changes, use the earlier time so the value
    // cannot look fresher than either record.
    return QuotaSnapshot(
      weeklyUsedPercent: weekly?.used, weeklyResetsAt: weekly?.resetsAt,
      observedAt: min(observed, modifiedAt), fetchedAt: now, source: .claudeStatusline)
  }
}

actor ClaudeVersionCache {
  static let shared = ClaudeVersionCache()
  /// User-Agent version used while no `claude --version` read has succeeded. It only keeps the
  /// CLI's `X.Y.Z` format; no server behavior has been verified to depend on this exact value.
  static let fallback = "2.1.0"
  /// Concurrent callers share one in-flight read; only a successful read stays cached.
  private var task: Task<String?, Never>?
  func version(executable: String, runner: any CommandRunning) async -> String {
    let task = self.task ?? Task { await Self.read(executable: executable, runner: runner) }
    self.task = task
    let version = await task.value
    // A failed read (for example a timeout right after login) is retried by the next fetch.
    if version == nil, self.task == task { self.task = nil }
    return version ?? Self.fallback
  }
  private static func read(executable: String, runner: any CommandRunning) async -> String? {
    guard
      let output = try? await runner.run(
        executable: executable, arguments: ["--version"], environment: [:], timeout: 5),
      output.status == 0,
      let text = String(data: output.data, encoding: .utf8),
      let first = text.split(whereSeparator: \.isWhitespace).first,
      first.range(of: #"^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression)
        != nil
    else { return nil }
    return String(first)
  }
}

public protocol ClaudeTokenRefreshing: Sendable {
  /// Starts a background CLI run for an expired access token and returns without waiting for it.
  /// The same token is retried a bounded number of times, spaced apart, before giving up.
  @discardableResult
  func refreshInBackground(executable: String, account: Account, expired: OAuthCredential) async
    -> Task<Void, Never>?
}
/// One line of `token-refresh.log`. Holds no token, prompt, or CLI output.
public struct TokenRefreshLogEntry: Codable, Equatable, Sendable {
  public enum Event: String, Codable, Sendable { case started, finished }
  /// `exited` carries `exitStatus`; `timedOut` hit the deadline; `launchFailed` never started the CLI.
  public enum Outcome: String, Codable, Sendable { case exited, timedOut, launchFailed }
  public var event: Event
  public var time: Date
  public var account: UUID
  public var configDir: String
  public var outcome: Outcome?
  public var exitStatus: Int32?
  public var durationSeconds: Double?
  public init(
    event: Event, time: Date, account: UUID, configDir: String, outcome: Outcome? = nil,
    exitStatus: Int32? = nil, durationSeconds: Double? = nil
  ) {
    self.event = event
    self.time = time
    self.account = account
    self.configDir = configDir
    self.outcome = outcome
    self.exitStatus = exitStatus
    self.durationSeconds = durationSeconds
  }
}
public protocol TokenRefreshLogging: Sendable {
  func append(_ entry: TokenRefreshLogEntry)
}
/// Appends JSON lines to `<app data>/token-refresh.log`, keeping one previous file (`.1`) once it reaches `maxBytes`.
public struct TokenRefreshLog: TokenRefreshLogging {
  public let file: URL
  public let maxBytes: Int
  public init(directory: URL = Paths.applicationSupport, maxBytes: Int = 262_144) {
    file = directory.appendingPathComponent("token-refresh.log")
    self.maxBytes = maxBytes
  }
  public func append(_ entry: TokenRefreshLogEntry) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    guard var line = try? encoder.encode(entry) else { return }
    line.append(10)
    PrivateLogFile.append(line, to: file, maxBytes: maxBytes)
  }
}

/// Lets the official CLI refresh an expired token; the app itself never uses the refresh token or writes the Keychain.
/// Verified 2026-11-13: a `claude -p` call refreshes and rotates the stored token even when the model reply is refused,
/// while `claude auth status` does not refresh.
public actor ClaudeTokenRefresher: ClaudeTokenRefreshing {
  public static let shared = ClaudeTokenRefresher()
  /// Smallest model call; no tools, sessions, settings (hooks, plugins), MCP servers, or slash commands.
  public static let arguments = [
    "-p", "Reply with OK.", "--model", "haiku", "--tools", "", "--no-session-persistence",
    "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
  ]
  public static let timeout: TimeInterval = 60
  /// Re-runs allowed after the first run while the same expired token is still in the Keychain.
  public static let maxRetries = 3
  /// Minimum gap between runs for the same expired token.
  public static let retryInterval: TimeInterval = 1800
  private let runner: any CommandRunning
  private let log: any TokenRefreshLogging
  private let clock: any UsageClock
  private let workingDirectory: URL
  /// Runs started and the last start time, keyed by the fingerprint of (config dir, expired token).
  /// Memory only: an app restart starts over.
  private var attempts: [String: (runs: Int, lastStart: Date)] = [:]
  public init(
    runner: any CommandRunning = LiveCommandRunner(),
    log: any TokenRefreshLogging = TokenRefreshLog(), clock: any UsageClock = SystemClock(),
    workingDirectory: URL = Paths.claudeRefreshWorkdir()
  ) {
    self.runner = runner
    self.log = log
    self.clock = clock
    self.workingDirectory = workingDirectory
  }
  /// Runs the CLI the way it stored the expired login, so it refreshes that same Keychain item.
  @discardableResult
  public func refreshInBackground(executable: String, account: Account, expired: OAuthCredential)
    -> Task<Void, Never>?
  {
    let expiredToken = expired.accessToken
    // Seeing the same expired token again means the previous run did not refresh it. Retry a few times,
    // spaced apart, to recover from transient failures without re-running every poll after a permanent
    // one (for example an ended login). The CLI exit status cannot tell these apart.
    let key = Paths.fingerprint(account.expandedDirectory + "\u{0}" + expiredToken)
    let started = clock.now()
    if let previous = attempts[key] {
      guard previous.runs <= Self.maxRetries,
        started.timeIntervalSince(previous.lastStart) >= Self.retryInterval
      else { return nil }
    }
    attempts[key] = ((attempts[key]?.runs ?? 0) + 1, started)
    let runner = runner
    let environment = Paths.claudeEnvironment(
      configDir: account.expandedDirectory, variable: expired.configDirVariable)
    let workingDirectory = workingDirectory
    // A missing directory makes the launch fail, which is logged as launchFailed.
    try? FileManager.default.createDirectory(
      at: workingDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    log.append(
      TokenRefreshLogEntry(
        event: .started, time: started, account: account.id, configDir: account.expandedDirectory))
    // Detached so a collection restart does not cancel a refresh that may already be rotating the token.
    return Task.detached {
      var outcome = TokenRefreshLogEntry.Outcome.exited
      var status: Int32?
      do {
        // Output is discarded: it may contain the model reply and is never logged.
        status = try await runner.run(
          executable: executable, arguments: Self.arguments, environment: environment,
          currentDirectory: workingDirectory, timeout: Self.timeout
        ).status
      } catch let error as CollectError where error.kind == .timeout {
        outcome = .timedOut
      } catch {
        outcome = .launchFailed
      }
      await self.finish(account: account, started: started, outcome: outcome, status: status)
    }
  }
  private func finish(
    account: Account, started: Date, outcome: TokenRefreshLogEntry.Outcome, status: Int32?
  ) {
    let now = clock.now()
    log.append(
      TokenRefreshLogEntry(
        event: .finished, time: now, account: account.id, configDir: account.expandedDirectory,
        outcome: outcome, exitStatus: status,
        durationSeconds: (now.timeIntervalSince(started) * 1000).rounded() / 1000))
  }
}

public struct ClaudeUsageCollector: Collector {
  private let credentials: any CredentialReading
  private let transport: any UsageHTTPTransport
  private let statusline: any StatuslineReading
  private let identity: any ClaudeIdentityReading
  private let runner: any CommandRunning
  private let clock: any UsageClock
  private let claudePath: @Sendable () -> String?
  private let source: ClaudeSource
  private let refresher: (any ClaudeTokenRefreshing)?
  public init(
    credentials: any CredentialReading = ClaudeCredentialReader(),
    transport: any UsageHTTPTransport = EphemeralHTTPTransport(),
    statusline: any StatuslineReading = StatuslineReader(),
    identity: any ClaudeIdentityReading = ClaudeIdentityReader(),
    runner: any CommandRunning = LiveCommandRunner(), clock: any UsageClock = SystemClock(),
    source: ClaudeSource = .oauthWithStatusline,
    refresher: (any ClaudeTokenRefreshing)? = ClaudeTokenRefresher.shared,
    claudePath: @escaping @Sendable () -> String? = { Executables.resolveClaude() }
  ) {
    self.credentials = credentials
    self.transport = transport
    self.statusline = statusline
    self.identity = identity
    self.runner = runner
    self.clock = clock
    self.claudePath = claudePath
    self.source = source
    self.refresher = refresher
  }
  public func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    // Statusline-only must not touch credentials, identity files, the CLI, or HTTP.
    if source == .statuslineOnly {
      guard let snapshot = statusline.read(configDir: account.expandedDirectory, now: clock.now())
      else { return .failure(CollectError(.statuslineMissing)) }
      return .success(CollectedUsage(snapshot))
    }
    var variable: ClaudeConfigDirVariable?
    do {
      let credential = try await credentials.read(configDir: account.expandedDirectory)
      variable = credential.configDirVariable
      // Expiry alone means the CLI has not refreshed lately; 401 and missing credentials stay authRequired.
      guard credential.expiresAt > clock.now() else {
        // The refreshed token is picked up by the next scheduled fetch, which re-reads the Keychain.
        if let refresher, let path = claudePath() {
          await refresher.refreshInBackground(
            executable: path, account: account, expired: credential)
        }
        throw CollectError(.tokenExpired)
      }
      var version = ClaudeVersionCache.fallback
      if let path = claudePath() {
        version = await ClaudeVersionCache.shared.version(executable: path, runner: runner)
      }
      // Unofficial endpoint that Claude Code reads its own usage from. The path, the `oauth-2025-04-20`
      // beta value, and the `claude-cli/<version> (external, <entrypoint>)` User-Agent format were found
      // in the Claude Code 2.1.322 binary on 2026-11-15; the CLI's actual header set was not captured.
      var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
      request.httpMethod = "GET"
      request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
      request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("claude-cli/\(version) (external, cli)", forHTTPHeaderField: "User-Agent")
      let response = try await transport.send(request)
      switch response.status {
      case 200: break
      case 401: throw CollectError(.authRequired)
      case 429:
        throw CollectError(
          .rateLimited, retryAt: Self.retryAt(response.retryAfter, now: clock.now()))
      default: throw CollectError(.http(response.status))
      }
      var snapshot = try Self.parse(response.body, now: clock.now())
      snapshot.identityFingerprint = identity.fingerprint(
        configDir: account.expandedDirectory, variable: variable)
      return .success(CollectedUsage(snapshot))
    } catch {
      let collectError = error as? CollectError
      var fallback = statusline.read(configDir: account.expandedDirectory, now: clock.now())
      fallback?.identityFingerprint = identity.fingerprint(
        configDir: account.expandedDirectory, variable: variable)
      return .failure(
        CollectError(
          collectError?.kind ?? .transport, fallback: fallback, retryAt: collectError?.retryAt))
    }
  }
  /// Longest `Retry-After` honored; a larger value is clamped so a bad header cannot stop polling for days.
  public static let maximumRetryAfter: TimeInterval = 86_400
  /// Parses `Retry-After` as delay seconds or an HTTP date (RFC 9110 §10.2.3).
  public static func retryAt(_ header: String?, now: Date) -> Date? {
    guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
      return nil
    }
    let delay: TimeInterval
    if value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let seconds = TimeInterval(value)
    {
      delay = seconds
    } else {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "GMT")
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      guard let date = formatter.date(from: value) else { return nil }
      delay = date.timeIntervalSince(now)
    }
    return now.addingTimeInterval(min(maximumRetryAfter, max(0, delay)))
  }
  public static func parse(_ data: Data, now: Date) throws -> QuotaSnapshot {
    // Only the `seven_day` key is read. Verified 2026-11-15 against two Claude accounts (Claude Code
    // 2.1.322): `seven_day` is present, while `five_hour`, `seven_day_sonnet`, and `seven_day_opus`
    // are null. These observations do not establish the response shape for every account.
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = root["seven_day"]
    else { throw CollectError(.schema) }
    var weekly: (used: Double, resetsAt: Date?)?
    if !(raw is NSNull) {
      guard let value = raw as? [String: Any], let used = Parsing.percent(value["utilization"])
      else { throw CollectError(.schema) }
      weekly = (used, Parsing.isoDate(value["resets_at"]))
    }
    return QuotaSnapshot(
      weeklyUsedPercent: weekly?.used, weeklyResetsAt: weekly?.resetsAt, observedAt: now,
      fetchedAt: now, source: .claudeOAuth)
  }
}
