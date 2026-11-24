import XCTest

@testable import DeltaveeCore

private actor FakeRPC: CodexRPCTransport {
  let data: Data
  let account: Data?
  var directory: String?
  init(_ data: Data, account: Data? = nil) {
    self.data = data
    self.account = account
  }
  func rateLimits(executable: String, configDir: String) async throws -> Data {
    directory = configDir
    return data
  }
  func read(executable: String, configDir: String) async throws -> CodexAppServerReplies {
    directory = configDir
    return CodexAppServerReplies(rateLimits: data, account: account)
  }
}
/// Conforms with only the original requirement, as an existing `DeltaveeCore` client would.
private struct RateLimitsOnlyRPC: CodexRPCTransport {
  let data: Data
  func rateLimits(executable: String, configDir: String) async throws -> Data { data }
}

final class CodexCollectorTests: CoreTestCase {
  func testMissingSevenDayDisplaysDash() throws {
    let data = Data(
      #"{"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300},"secondary":null}}}"#
        .utf8)
    let value = try CodexAppServerCollector.parse(data, now: now)
    var a = account(.openai)
    let state = StateReducer.applying(
      .success(CollectedUsage(value)), to: .neverFetched, account: &a)
    XCTAssertNil(value.weeklyUsedPercent)
    XCTAssertEqual(
      IconRenderer.parts(accounts: [a], states: [a.id: state], mode: .used, now: now).first?.text,
      "Test --")
  }
  func testUnknownWindowsIgnored() throws {
    let data = Data(
      #"{"result":{"rateLimits":{"primary":{"usedPercent":88,"windowDurationMins":60},"secondary":{"usedPercent":31,"windowDurationMins":10080}},"unknown":{"usedPercent":100}}}"#
        .utf8)
    let value = try CodexAppServerCollector.parse(data, now: now)
    XCTAssertEqual(value.weeklyUsedPercent, 31)
  }
  func testCodexFixtureContract() throws {
    let value = try CodexAppServerCollector.parse(fixture("codex"), now: now)
    XCTAssertEqual(value.weeklyUsedPercent, 64)
    XCTAssertEqual(value.weeklyResetsAt, Date(timeIntervalSince1970: 1_900_500_000))
    XCTAssertEqual(value.source, .codexAppServer)
    XCTAssertEqual(value.identityFingerprint, Paths.fingerprint("fake-test-account"))
  }
  func testCodexMissingBinaryAndAuthAndSchema() async throws {
    let rpc = FakeRPC(try fixture("codex"))
    let c = CodexAppServerCollector(
      transport: rpc, clock: FixedClock(date: now), executable: { nil })
    guard case .failure(let failure) = await c.fetch(account(.openai)) else {
      return XCTFail("Expected missing binary")
    }
    XCTAssertEqual(failure.kind, .binaryNotFound)
    let calls = await rpc.directory
    XCTAssertNil(calls)
    for (json, expected) in [
      (#"{"error":{"code":401,"message":"fake auth required"}}"#, FailureKind.authRequired),
      (#"{"result":{}}"#, .schema),
    ] {
      XCTAssertThrowsError(try CodexAppServerCollector.parse(Data(json.utf8), now: now)) { error in
        XCTAssertEqual((error as? CollectError)?.kind, expected)
      }
    }
  }
  func testCodexCollectorUsesInjectedTransportAndClock() async throws {
    let rpc = FakeRPC(try fixture("codex"))
    let c = CodexAppServerCollector(
      transport: rpc, clock: FixedClock(date: now), executable: { "/fake/codex" })
    guard case .success(let usage) = await c.fetch(account(.openai)) else {
      return XCTFail("Expected parsed RPC")
    }
    XCTAssertEqual(usage.snapshot.observedAt, now)
    let dir = await rpc.directory
    XCTAssertEqual(dir, account().expandedDirectory)
  }
  func testCodexNullAndMissingDurationWindowsAreSkipped() throws {
    for duration in ["\"windowDurationMins\":null,", ""] {
      let data = Data(
        "{\"result\":{\"rateLimits\":{\"primary\":{\(duration)\"usedPercent\":12},\"secondary\":{\"windowDurationMins\":10080,\"usedPercent\":31}}}}"
          .utf8)
      let value = try CodexAppServerCollector.parse(data, now: now)
      XCTAssertEqual(value.weeklyUsedPercent, 31)
    }
  }
  func testCodexInvalidWeeklyPercentFailsInsteadOfBlanking() {
    for value in ["101", "-1", "null"] {
      let data = Data(
        "{\"result\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":12},\"secondary\":{\"windowDurationMins\":10080,\"usedPercent\":\(value)}}}}"
          .utf8)
      XCTAssertThrowsError(try CodexAppServerCollector.parse(data, now: now)) {
        XCTAssertEqual(($0 as? CollectError)?.kind, .schema)
      }
    }
    let nonWeeklyBad = Data(
      "{\"result\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":101},\"secondary\":{\"windowDurationMins\":10080,\"usedPercent\":31}}}}"
        .utf8)
    XCTAssertEqual(try? CodexAppServerCollector.parse(nonWeeklyBad, now: now).weeklyUsedPercent, 31)
  }
  func testAccountReadDistinguishesNoEmailFromUnknown() {
    let cases: [(String?, EmailObservation)] = [
      (
        #"{"id":3,"result":{"account":{"type":"chatgpt","email":" fake@example.com "}}}"#,
        .address("fake@example.com")
      ),
      (#"{"id":3,"result":{"account":null,"requiresOpenaiAuth":true}}"#, .absent),
      (#"{"id":3,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}"#, .absent),
      (
        #"{"id":3,"result":{"account":{"type":"amazonBedrock","credentialSource":"awsManaged"}}}"#,
        .absent
      ),
      (#"{"id":3,"result":{"account":{"type":"chatgpt","email":""}}}"#, .unknown),
      (#"{"id":3,"error":{"code":-32601,"message":"fake method not found"}}"#, .unknown),
      (#"{"id":3,"result":{}}"#, .unknown),
      (nil, .unknown),
    ]
    for (json, expected) in cases {
      XCTAssertEqual(
        CodexAppServerCollector.email(json.map { Data($0.utf8) }), expected, json ?? "no reply")
    }
  }
  func testAccountEmailIsReportedWhenQuotaFails() async {
    // No `accountId`, so no fingerprint change could signal the sign-out.
    let rpc = FakeRPC(
      Data(#"{"error":{"code":-32600,"message":"fake auth required"}}"#.utf8),
      account: Data(#"{"id":3,"result":{"account":null}}"#.utf8))
    let c = CodexAppServerCollector(
      transport: rpc, clock: FixedClock(date: now), executable: { "/fake/codex" })
    guard case .failure(let failure) = await c.fetch(account(.openai)) else {
      return XCTFail("Expected sign-in failure")
    }
    XCTAssertEqual(failure.kind, .authRequired)
    XCTAssertEqual(failure.email, .absent)
  }
  func testExistingContractsKeepWorkingWithoutEmail() async throws {
    let c = CodexAppServerCollector(
      transport: RateLimitsOnlyRPC(data: try fixture("codex")), clock: FixedClock(date: now),
      executable: { "/fake/codex" })
    guard case .success(let usage) = await c.fetch(account(.openai)) else {
      return XCTFail("Expected parsed RPC")
    }
    XCTAssertEqual(usage.snapshot.weeklyUsedPercent, 64)
    XCTAssertEqual(usage.email, .unknown, "A transport without account replies keeps the email")

    let error = CollectError(.authRequired, retryAt: now, email: .address("fake@example.com"))
    let encoded = try JSONEncoder().encode(error)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fake@example.com"))
    let decoded = try JSONDecoder().decode(CollectError.self, from: encoded)
    XCTAssertEqual(decoded, CollectError(.authRequired, retryAt: now))
  }
}
