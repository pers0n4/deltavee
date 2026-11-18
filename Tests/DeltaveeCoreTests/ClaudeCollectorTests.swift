import XCTest

@testable import DeltaveeCore

private final class SettableClock: UsageClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  init(_ date: Date) { current = date }
  var date: Date {
    get { lock.withLock { current } }
    set { lock.withLock { current = newValue } }
  }
  func now() -> Date { date }
}
private struct FakeIdentity: ClaudeIdentityReading {
  func fingerprint(configDir: String, variable: ClaudeConfigDirVariable?) -> String? {
    Paths.fingerprint("fake-test-identity")
  }
}
private func expiredCredential(_ token: String, _ variable: ClaudeConfigDirVariable = .set)
  -> OAuthCredential
{
  OAuthCredential(
    accessToken: token, expiresAt: Date(timeIntervalSince1970: 0), configDirVariable: variable)
}
/// Answers `security find-generic-password` per service; unknown services exit 44 like a missing item.
private actor KeychainRunner: CommandRunning {
  var services: [String] = []
  let items: [String: Data]
  init(items: [String: Data]) { self.items = items }
  func run(
    executable: String, arguments: [String], environment: [String: String],
    currentDirectory: URL?, timeout: TimeInterval
  ) async throws -> CommandOutput {
    let service = arguments[arguments.firstIndex(of: "-s")! + 1]
    services.append(service)
    guard let data = items[service] else { return CommandOutput(status: 44, data: Data()) }
    return CommandOutput(status: 0, data: data)
  }
}
private struct NoStatusline: StatuslineReading {
  func read(configDir: String, now: Date) -> QuotaSnapshot? { nil }
}
private struct FakeStatusline: StatuslineReading {
  let value: QuotaSnapshot
  func read(configDir: String, now: Date) -> QuotaSnapshot? { value }
}
private actor FakeCredentials: CredentialReading {
  var count = 0
  let expiry: Date
  let variable: ClaudeConfigDirVariable
  init(expiry: Date, variable: ClaudeConfigDirVariable = .set) {
    self.expiry = expiry
    self.variable = variable
  }
  func read(configDir: String) async throws -> OAuthCredential {
    count += 1
    return OAuthCredential(
      accessToken: "fake-test-token", expiresAt: expiry, configDirVariable: variable)
  }
}
private actor FakeHTTP: UsageHTTPTransport {
  var count = 0
  var validHeaders = false
  let response: HTTPResult
  init(status: Int = 200, body: Data = Data(), retryAfter: String? = nil) {
    response = HTTPResult(status: status, body: body, retryAfter: retryAfter)
  }
  func send(_ request: URLRequest) async throws -> HTTPResult {
    count += 1
    validHeaders =
      request.httpMethod == "GET"
      && request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage"
      && request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20"
      && request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-test-token"
      && request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.0 (external, cli)"
    return response
  }
}
private actor FakeRunner: CommandRunning {
  var count = 0
  var arguments: [String] = []
  var executable = ""
  var environment: [String: String] = [:]
  var currentDirectory: URL?
  let output: CommandOutput
  init(status: Int32 = 0, data: Data = Data()) {
    output = CommandOutput(status: status, data: data)
  }
  func run(
    executable: String, arguments: [String], environment: [String: String],
    currentDirectory: URL?, timeout: TimeInterval
  ) async throws -> CommandOutput {
    count += 1
    self.arguments = arguments
    self.executable = executable
    self.environment = environment
    self.currentDirectory = currentDirectory
    return output
  }
}
private actor FakeRefresher: ClaudeTokenRefreshing {
  var calls:
    [(executable: String, configDir: String, token: String, variable: ClaudeConfigDirVariable)] =
      []
  func refreshInBackground(executable: String, account: Account, expired: OAuthCredential) -> Task<
    Void, Never
  >? {
    calls.append(
      (executable, account.expandedDirectory, expired.accessToken, expired.configDirVariable))
    return nil
  }
}
private final class RecordingRefreshLog: TokenRefreshLogging, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [TokenRefreshLogEntry] = []
  var entries: [TokenRefreshLogEntry] { lock.withLock { stored } }
  func append(_ entry: TokenRefreshLogEntry) { lock.withLock { stored.append(entry) } }
}
private struct ThrowingRunner: CommandRunning {
  let error: any Error
  func run(
    executable: String, arguments: [String], environment: [String: String],
    currentDirectory: URL?, timeout: TimeInterval
  ) async throws -> CommandOutput { throw error }
}

final class ClaudeCollectorTests: CoreTestCase {
  private func collector(
    credentials: FakeCredentials, http: FakeHTTP,
    statusline: any StatuslineReading = NoStatusline(), source: ClaudeSource = .oauthWithStatusline,
    runner: FakeRunner = FakeRunner(), refresher: FakeRefresher? = nil, claudePath: String? = nil
  ) -> ClaudeUsageCollector {
    ClaudeUsageCollector(
      credentials: credentials, transport: http, statusline: statusline, identity: FakeIdentity(),
      runner: runner, clock: FixedClock(date: now), source: source, refresher: refresher,
      claudePath: { claudePath })
  }
  func testStatuslineRereadRemainsStale() throws {
    let value = try StatuslineReader.parse(fixture("statusline"), modifiedAt: now, now: now)
    XCTAssertEqual(value.fetchedAt, now)
    XCTAssertEqual(value.observedAt, now.addingTimeInterval(-7200))
    XCTAssertTrue(value.isStale(now: now))
  }
  func testStatuslineUsesEarlierMtime() throws {
    let modified = now.addingTimeInterval(-10000)
    let value = try StatuslineReader.parse(fixture("statusline"), modifiedAt: modified, now: now)
    XCTAssertEqual(value.observedAt, modified)
  }
  func testClaudeServiceDefaultAndHash8NFC() {
    XCTAssertEqual(
      Paths.claudeService(configDir: "~/.claude", variable: .unset), "Claude Code-credentials")
    XCTAssertEqual(
      Paths.claudeService(configDir: "~/.claude", variable: .set),
      "Claude Code-credentials-" + Paths.fingerprint(Paths.absolute("~/.claude")).prefix(8))
    let path = "/tmp/fake-cafe\u{301}"
    let expected = "Claude Code-credentials-" + Paths.fingerprint(Paths.absolute(path)).prefix(8)
    XCTAssertEqual(Paths.claudeService(configDir: path, variable: .set), expected)
    XCTAssertEqual(
      Paths.claudeService(configDir: path, variable: .set),
      Paths.claudeService(configDir: "/tmp/fake-café", variable: .set))
    XCTAssertEqual(Paths.claudeConfigDirVariables(configDir: "~/.claude/"), [.unset, .set])
    XCTAssertEqual(Paths.claudeConfigDirVariables(configDir: path), [.set])
  }
  func testDefaultDirectoryFindsLoginMadeWithConfigDirVariable() async throws {
    let unset = Paths.claudeService(configDir: "~/.claude", variable: .unset)
    let scoped = Paths.claudeService(configDir: "~/.claude", variable: .set)
    func item(_ token: String, _ expiresAt: Int) -> Data {
      Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(expiresAt)}}"#.utf8)
    }
    let onlyScoped = KeychainRunner(items: [scoped: item("fake-scoped", 1_900_000_000_000)])
    let found = try await ClaudeCredentialReader(runner: onlyScoped).read(configDir: "~/.claude")
    XCTAssertEqual(found.accessToken, "fake-scoped")
    XCTAssertEqual(found.configDirVariable, .set)
    let services = await onlyScoped.services
    XCTAssertEqual(services, [unset, scoped])
    for (unsetExpiry, scopedExpiry, winner) in [
      (1_900_000_000_000, 1_800_000_000_000, ClaudeConfigDirVariable.unset),
      (1_800_000_000_000, 1_900_000_000_000, .set),
    ] {
      let both = KeychainRunner(items: [
        unset: item("fake-unset", unsetExpiry), scoped: item("fake-scoped", scopedExpiry),
      ])
      let read = try await ClaudeCredentialReader(runner: both).read(configDir: "~/.claude")
      XCTAssertEqual(read.configDirVariable, winner, "The later expiry wins")
    }
    let other = KeychainRunner(items: [:])
    _ = try? await ClaudeCredentialReader(runner: other).read(configDir: "/tmp/fake-deltavee-none")
    let otherServices = await other.services
    XCTAssertEqual(
      otherServices, [Paths.claudeService(configDir: "/tmp/fake-deltavee-none", variable: .set)],
      "Other directories never fall back to the default item")
  }
  func testIdentityFollowsCredentialVariableOrNewestFile() throws {
    let root = try temporaryDirectory()
    let files: [ClaudeConfigDirVariable: URL] = [
      .unset: root.appendingPathComponent("home.claude.json"),
      .set: root.appendingPathComponent("dir.claude.json"),
    ]
    for (variable, file) in files {
      try Data(#"{"oauthAccount":{"accountUuid":"fake-\#(variable)"}}"#.utf8).write(to: file)
    }
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: files[.set]!.path)
    let reader = ClaudeIdentityReader { _, variable in files[variable]! }
    XCTAssertEqual(
      reader.fingerprint(configDir: "~/.claude", variable: .set), Paths.fingerprint("fake-set"))
    XCTAssertEqual(
      reader.fingerprint(configDir: "~/.claude", variable: .unset),
      Paths.fingerprint("fake-unset"))
    XCTAssertEqual(
      reader.fingerprint(configDir: "~/.claude", variable: nil), Paths.fingerprint("fake-unset"),
      "Without a credential the newer file wins")
    XCTAssertEqual(
      reader.fingerprint(configDir: "/tmp/fake-deltavee-config", variable: nil),
      Paths.fingerprint("fake-set"), "Other directories only have the variable's file")
  }
  func testExpiredTokenIsDistinctFromAuthFailureAndSkipsNetwork() async {
    let credentials = FakeCredentials(expiry: now)
    let http = FakeHTTP()
    let result = await collector(credentials: credentials, http: http).fetch(account())
    guard case .failure(let error) = result else { return XCTFail("Expected tokenExpired") }
    XCTAssertEqual(error.kind, .tokenExpired)
    let calls = await http.count
    XCTAssertEqual(calls, 0)
  }
  func testExpiredTokenStartsOneBackgroundRefreshPerFetch() async {
    let refresher = FakeRefresher()
    let http = FakeHTTP()
    let c = collector(
      credentials: FakeCredentials(expiry: now), http: http, refresher: refresher,
      claudePath: "/fake/claude")
    guard case .failure(let error) = await c.fetch(account()) else {
      return XCTFail("Expected tokenExpired")
    }
    XCTAssertEqual(error.kind, .tokenExpired)
    let calls = await refresher.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.executable, "/fake/claude")
    XCTAssertEqual(calls.first?.configDir, "/tmp/fake-deltavee-config")
    XCTAssertEqual(calls.first?.token, "fake-test-token")
    XCTAssertEqual(calls.first?.variable, .set)
    _ = await collector(
      credentials: FakeCredentials(expiry: now, variable: .unset), http: http, refresher: refresher,
      claudePath: "/fake/claude"
    ).fetch(account())
    let unsetCall = await refresher.calls.last
    XCTAssertEqual(unsetCall?.variable, .unset, "The refresh runs the way the login was stored")
    let requests = await http.count
    XCTAssertEqual(requests, 0)
  }
  func testRefreshIsNotStartedForValidTokenMissingCLIOrStatuslineOnly() async throws {
    let refresher = FakeRefresher()
    _ = await collector(
      credentials: FakeCredentials(expiry: now.addingTimeInterval(600)),
      http: FakeHTTP(body: try fixture("claude")), refresher: refresher, claudePath: "/fake/claude"
    ).fetch(account())
    _ = await collector(
      credentials: FakeCredentials(expiry: now), http: FakeHTTP(), refresher: refresher,
      claudePath: nil
    ).fetch(account())
    _ = await collector(
      credentials: FakeCredentials(expiry: now), http: FakeHTTP(), source: .statuslineOnly,
      refresher: refresher, claudePath: "/fake/claude"
    ).fetch(account())
    let calls = await refresher.calls
    XCTAssertTrue(calls.isEmpty)
  }
  func testTokenRefresherRunsMinimalCLIOncePerExpiredToken() async throws {
    let runner = FakeRunner()
    let workdir = try temporaryDirectory().appendingPathComponent("refresh-workdir")
    let refresher = ClaudeTokenRefresher(
      runner: runner, log: RecordingRefreshLog(), workingDirectory: workdir)
    let custom = Account(name: "Dev", provider: .anthropic, configDir: "/tmp/fake-deltavee-config/")
    await refresher.refreshInBackground(
      executable: "/fake/claude", account: custom, expired: expiredCredential("fake-old"))?.value
    var count = await runner.count
    XCTAssertEqual(count, 1)
    let executable = await runner.executable
    let arguments = await runner.arguments
    var environment = await runner.environment
    XCTAssertEqual(executable, "/fake/claude")
    XCTAssertEqual(arguments, ClaudeTokenRefresher.arguments)
    XCTAssertEqual(
      Array(arguments.prefix(4)), ["-p", "Reply with OK.", "--model", "haiku"])
    XCTAssertTrue(arguments.contains("--no-session-persistence"))
    XCTAssertTrue(arguments.contains("--strict-mcp-config"))
    XCTAssertEqual(environment, ["CLAUDE_CONFIG_DIR": "/tmp/fake-deltavee-config"])
    let directory = await runner.currentDirectory
    XCTAssertEqual(directory, workdir)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: workdir.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: workdir.path), [],
      "The refresh working directory stays empty")
    let repeated = await refresher.refreshInBackground(
      executable: "/fake/claude", account: custom, expired: expiredCredential("fake-old"))
    XCTAssertNil(repeated)
    count = await runner.count
    XCTAssertEqual(count, 1)
    let standard = Account(name: "Main", provider: .anthropic, configDir: "~/.claude")
    await refresher.refreshInBackground(
      executable: "/fake/claude", account: standard, expired: expiredCredential("fake-old", .unset)
    )?.value
    environment = await runner.environment
    XCTAssertEqual(environment, [:])
    await refresher.refreshInBackground(
      executable: "/fake/claude", account: standard,
      expired: expiredCredential("fake-scoped", .set))?.value
    environment = await runner.environment
    XCTAssertEqual(environment, ["CLAUDE_CONFIG_DIR": Paths.absolute("~/.claude")])
    await refresher.refreshInBackground(
      executable: "/fake/claude", account: custom, expired: expiredCredential("fake-newer"))?.value
    count = await runner.count
    XCTAssertEqual(count, 4)
  }
  func testTokenRefreshLogsStartAndOutcomeWithoutTokenOrOutput() async throws {
    let log = RecordingRefreshLog()
    let custom = Account(name: "Dev", provider: .anthropic, configDir: "/tmp/fake-deltavee-config")
    let output = Data("fake-model-reply fake-old".utf8)
    await ClaudeTokenRefresher(
      runner: FakeRunner(status: 1, data: output), log: log, clock: FixedClock(date: now),
      workingDirectory: try temporaryDirectory()
    ).refreshInBackground(
      executable: "/fake/claude", account: custom, expired: expiredCredential("fake-old"))?
      .value
    XCTAssertEqual(
      log.entries,
      [
        TokenRefreshLogEntry(
          event: .started, time: now, account: custom.id, configDir: "/tmp/fake-deltavee-config"),
        TokenRefreshLogEntry(
          event: .finished, time: now, account: custom.id, configDir: "/tmp/fake-deltavee-config",
          outcome: .exited, exitStatus: 1, durationSeconds: 0),
      ])
    for (error, outcome) in [
      (CollectError(.timeout) as any Error, TokenRefreshLogEntry.Outcome.timedOut),
      (CocoaError(.fileNoSuchFile), .launchFailed),
    ] {
      let failing = RecordingRefreshLog()
      await ClaudeTokenRefresher(
        runner: ThrowingRunner(error: error), log: failing, clock: FixedClock(date: now),
        workingDirectory: try temporaryDirectory()
      ).refreshInBackground(
        executable: "/fake/claude", account: custom, expired: expiredCredential("fake-old"))?
        .value
      XCTAssertEqual(failing.entries.map(\.event), [.started, .finished])
      XCTAssertEqual(failing.entries.last?.outcome, outcome)
      XCTAssertNil(failing.entries.last?.exitStatus)
    }
    let skipped = RecordingRefreshLog()
    let once = ClaudeTokenRefresher(
      runner: FakeRunner(), log: skipped, clock: FixedClock(date: now),
      workingDirectory: try temporaryDirectory())
    await once.refreshInBackground(
      executable: "/fake/claude", account: custom, expired: expiredCredential("fake-old"))?.value
    await once.refreshInBackground(
      executable: "/fake/claude", account: custom, expired: expiredCredential("fake-old"))?.value
    XCTAssertEqual(skipped.entries.count, 2, "A repeated token neither runs nor logs")
  }
  func testTokenRefresherRetriesSameTokenThreeTimesThirtyMinutesApart() async throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = SettableClock(start)
    let runner = FakeRunner()
    let refresher = ClaudeTokenRefresher(
      runner: runner, log: RecordingRefreshLog(), clock: clock,
      workingDirectory: try temporaryDirectory())
    let account = Account(
      name: "Dev", provider: .anthropic, configDir: "/tmp/fake-deltavee-config/")
    func attempt(_ token: String = "fake-old", after seconds: TimeInterval) async -> Bool {
      clock.date = start.addingTimeInterval(seconds)
      guard
        let task = await refresher.refreshInBackground(
          executable: "/fake/claude", account: account, expired: expiredCredential(token))
      else { return false }
      await task.value
      return true
    }
    let retry = ClaudeTokenRefresher.retryInterval
    XCTAssertEqual(ClaudeTokenRefresher.maxRetries, 3)
    XCTAssertEqual(retry, 1800)
    var started: [Bool] = []
    started.append(await attempt(after: 0))  // first run
    started.append(await attempt(after: 600))  // next poll, too soon
    started.append(await attempt(after: retry - 1))  // still too soon
    started.append(await attempt(after: retry))  // retry 1
    started.append(await attempt(after: retry * 2))  // retry 2
    started.append(await attempt(after: retry * 2 + 600))  // too soon after retry 2
    started.append(await attempt(after: retry * 3))  // retry 3
    started.append(await attempt(after: retry * 4))  // limit reached
    started.append(await attempt(after: retry * 20))  // still given up
    XCTAssertEqual(started, [true, false, false, true, true, false, true, false, false])
    let count = await runner.count
    XCTAssertEqual(count, 4, "One run plus three retries for the same expired token")
    let restarted = await attempt("fake-new", after: retry * 20)
    XCTAssertTrue(restarted, "A different expired token starts over")
  }
  func testRefreshWorkdirIsFixedUnderAppData() {
    let root = URL(fileURLWithPath: "/tmp/fake-app-data", isDirectory: true)
    XCTAssertEqual(
      Paths.claudeRefreshWorkdir(root: root).path, "/tmp/fake-app-data/claude-refresh")
  }
  func testTokenRefreshLogFileIsPrivateJSONLinesAndRotates() throws {
    let directory = try temporaryDirectory().appendingPathComponent("app")
    let log = TokenRefreshLog(directory: directory, maxBytes: 400)
    let account = UUID()
    let entry = TokenRefreshLogEntry(
      event: .finished, time: now, account: account, configDir: "/tmp/fake-deltavee-config",
      outcome: .exited, exitStatus: 0, durationSeconds: 3.25)
    log.append(entry)
    let text = try String(contentsOf: log.file, encoding: .utf8)
    XCTAssertEqual(text.split(separator: "\n").count, 1)
    XCTAssertTrue(text.contains(#""time":"2030-03-17T19:46:40Z""#))
    XCTAssertTrue(text.contains(#""outcome":"exited""#))
    let attributes = try FileManager.default.attributesOfItem(atPath: log.file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    XCTAssertEqual(
      try decoder.decode(
        TokenRefreshLogEntry.self, from: Data(text.split(separator: "\n")[0].utf8)),
      entry)
    log.append(entry)
    log.append(entry)
    let previous = log.file.appendingPathExtension("1")
    XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
    let current = try String(contentsOf: log.file, encoding: .utf8)
    XCTAssertLessThanOrEqual(current.utf8.count, 400)
    XCTAssertGreaterThanOrEqual(current.split(separator: "\n").count, 1)
  }
  func testCredentialsRereadEveryFetch() async throws {
    let credentials = FakeCredentials(expiry: now.addingTimeInterval(600))
    let http = FakeHTTP(body: try fixture("claude"))
    let c = collector(credentials: credentials, http: http)
    _ = await c.fetch(account())
    _ = await c.fetch(account())
    let reads = await credentials.count
    let sends = await http.count
    let valid = await http.validHeaders
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(sends, 2)
    XCTAssertTrue(valid)
  }
  func testStatuslineOnlySkipsCredentialsHTTPAndProcess() async {
    let credentials = FakeCredentials(expiry: now)
    let http = FakeHTTP()
    let runner = FakeRunner()
    let value = snapshot()
    let c = collector(
      credentials: credentials, http: http, statusline: FakeStatusline(value: value),
      source: .statuslineOnly, runner: runner)
    let result = await c.fetch(account())
    guard case .success(let usage) = result else { return XCTFail("Expected statusline") }
    XCTAssertEqual(usage.snapshot, value)
    let reads = await credentials.count
    let sends = await http.count
    let spawns = await runner.count
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(sends, 0)
    XCTAssertEqual(spawns, 0)
  }
  func testClaudeFixtureContract() throws {
    let value = try ClaudeUsageCollector.parse(fixture("claude"), now: now)
    XCTAssertEqual(value.weeklyUsedPercent, 47)
    XCTAssertNotNil(value.weeklyResetsAt)
    XCTAssertEqual(value.observedAt, now)
  }
  func testStatuslineFixtureContract() throws {
    let value = try StatuslineReader.parse(fixture("statusline"), modifiedAt: now, now: now)
    XCTAssertEqual(value.weeklyUsedPercent, 73)
    XCTAssertEqual(value.source, .claudeStatusline)
  }
  func testOnlySevenDayBecomesWeekly() throws {
    let value = try ClaudeUsageCollector.parse(
      Data(
        #"{"seven_day":null,"five_hour":{"utilization":88},"seven_day_opus":{"utilization":77}}"#
          .utf8),
      now: now)
    XCTAssertNil(value.weeklyUsedPercent)
    XCTAssertThrowsError(
      try ClaudeUsageCollector.parse(
        Data(#"{"five_hour":{"utilization":88},"seven_day_opus":{"utilization":77}}"#.utf8),
        now: now)
    ) { XCTAssertEqual(($0 as? CollectError)?.kind, .schema) }
  }
  func testHTTPFailuresMapWithoutLeakingBody() async {
    for (status, kind) in [(401, FailureKind.authRequired), (429, .rateLimited), (503, .http(503))]
    {
      let c = collector(
        credentials: FakeCredentials(expiry: now.addingTimeInterval(500)),
        http: FakeHTTP(status: status))
      guard case .failure(let error) = await c.fetch(account()) else {
        return XCTFail("Expected mapped failure")
      }
      XCTAssertEqual(error.kind, kind)
    }
  }
  func testRetryAfterParsesSecondsAndHTTPDateWithClamp() {
    XCTAssertEqual(ClaudeUsageCollector.retryAt("120", now: now), now.addingTimeInterval(120))
    XCTAssertEqual(ClaudeUsageCollector.retryAt(" 0 ", now: now), now)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    let date = formatter.string(from: now.addingTimeInterval(900))
    XCTAssertEqual(ClaudeUsageCollector.retryAt(date, now: now), now.addingTimeInterval(900))
    let past = formatter.string(from: now.addingTimeInterval(-900))
    XCTAssertEqual(ClaudeUsageCollector.retryAt(past, now: now), now)
    XCTAssertEqual(
      ClaudeUsageCollector.retryAt("9999999", now: now),
      now.addingTimeInterval(ClaudeUsageCollector.maximumRetryAfter))
    for invalid in [nil, "", "-5", "1.5", "soon"] as [String?] {
      XCTAssertNil(ClaudeUsageCollector.retryAt(invalid, now: now), "\(invalid ?? "nil")")
    }
  }
  func testRateLimitedFetchCarriesRetryAfterAndFallback() async {
    let fallback = snapshot(observedAt: now.addingTimeInterval(-60))
    let c = collector(
      credentials: FakeCredentials(expiry: now.addingTimeInterval(500)),
      http: FakeHTTP(status: 429, retryAfter: "300"), statusline: FakeStatusline(value: fallback))
    guard case .failure(let error) = await c.fetch(account()) else {
      return XCTFail("Expected rate limit")
    }
    XCTAssertEqual(error.kind, .rateLimited)
    XCTAssertEqual(error.retryAt, now.addingTimeInterval(300))
    XCTAssertEqual(error.fallback?.observedAt, fallback.observedAt)
  }
  func testCredentialReaderUsesScopedServiceAndFileFallback() async throws {
    let directory = try temporaryDirectory()
    let fake = Data(
      #"{"claudeAiOauth":{"accessToken":"fake-fixture-token","expiresAt":1900000000000}}"#.utf8)
    try fake.write(to: directory.appendingPathComponent(".credentials.json"))
    let runner = FakeRunner(status: 44)
    let credential = try await ClaudeCredentialReader(runner: runner).read(
      configDir: directory.path)
    XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
    let args = await runner.arguments
    let binary = await runner.executable
    let count = await runner.count
    XCTAssertEqual(binary, "/usr/bin/security")
    XCTAssertEqual(
      args,
      [
        "find-generic-password", "-a", NSUserName(), "-s",
        Paths.claudeService(configDir: directory.path, variable: .set), "-w",
      ])
    XCTAssertEqual(count, 1)
  }
  func testInvalidPercentRejectedRatherThanDisplayed() {
    for value in ["-1", "101", "true"] {
      let json = "{\"seven_day\":{\"utilization\":\(value)}}"
      XCTAssertThrowsError(try ClaudeUsageCollector.parse(Data(json.utf8), now: now))
    }
  }
  func testStatuslineOnlyMissingHookIsNotAuthenticationFailure() async {
    let credentials = FakeCredentials(expiry: now)
    let http = FakeHTTP()
    let runner = FakeRunner()
    let c = collector(credentials: credentials, http: http, source: .statuslineOnly, runner: runner)
    guard case .failure(let error) = await c.fetch(account()) else {
      return XCTFail("Expected missing hook")
    }
    XCTAssertEqual(error.kind, .statuslineMissing)
    XCTAssertEqual(
      AccountState.failed(error.kind, lastSuccess: nil).message,
      "Statusline hook not installed or no data")
    let reads = await credentials.count
    let sends = await http.count
    let spawns = await runner.count
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(sends, 0)
    XCTAssertEqual(spawns, 0)
  }
  func testClaudeInvalidNonWeeklyWindowsAreIgnored() throws {
    let value = try ClaudeUsageCollector.parse(fixture("claude-auxiliary-invalid"), now: now)
    XCTAssertEqual(value.weeklyUsedPercent, 47)
    let statusline = Data(
      #"{"observedAt":1900000000,"rateLimits":{"seven_day":{"used_percentage":47},"five_hour":{"used_percentage":null}}}"#
        .utf8)
    XCTAssertEqual(
      try StatuslineReader.parse(statusline, modifiedAt: now, now: now).weeklyUsedPercent, 47)
  }
  func testClaudeMicrosecondOffsetResetParses() throws {
    let value = try ClaudeUsageCollector.parse(fixture("claude-auxiliary-invalid"), now: now)
    let date = try XCTUnwrap(value.weeklyResetsAt)
    XCTAssertEqual(date.timeIntervalSince1970, 1_794_405_600.933507, accuracy: 0.001)
  }
  func testClaudeVersionCacheRunsOnceWithoutAccountEnvironment() async {
    let cache = ClaudeVersionCache()
    let runner = FakeRunner(data: Data("2.1.0 (Claude Code)\n".utf8))
    async let first = cache.version(executable: "/fake/claude", runner: runner)
    async let second = cache.version(executable: "/fake/claude", runner: runner)
    let versions = await [first, second]
    XCTAssertEqual(versions, ["2.1.0", "2.1.0"])
    let count = await runner.count
    let environment = await runner.environment
    let args = await runner.arguments
    XCTAssertEqual(count, 1)
    XCTAssertTrue(environment.isEmpty)
    XCTAssertEqual(args, ["--version"])
  }
  func testClaudeVersionCacheRetriesAfterFailedReadAndKeepsSuccess() async {
    let cache = ClaudeVersionCache()
    let failing = FakeRunner(status: 1)
    let failed = await cache.version(executable: "/fake/claude", runner: failing)
    XCTAssertEqual(failed, ClaudeVersionCache.fallback)
    let malformed = FakeRunner(data: Data("not a version\n".utf8))
    let unparsed = await cache.version(executable: "/fake/claude", runner: malformed)
    XCTAssertEqual(unparsed, ClaudeVersionCache.fallback)
    let succeeding = FakeRunner(data: Data("2.3.4 (Claude Code)\n".utf8))
    let read = await cache.version(executable: "/fake/claude", runner: succeeding)
    XCTAssertEqual(read, "2.3.4")
    let later = FakeRunner(data: Data("9.9.9 (Claude Code)\n".utf8))
    let cached = await cache.version(executable: "/fake/claude", runner: later)
    XCTAssertEqual(cached, "2.3.4")
    let counts = await [failing.count, malformed.count, succeeding.count, later.count]
    XCTAssertEqual(counts, [1, 1, 1, 0])
  }
}
