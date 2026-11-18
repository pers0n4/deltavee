import XCTest

@testable import DeltaveeCore

private actor FakeRPC: CodexRPCTransport {
  let data: Data
  var directory: String?
  init(_ data: Data) { self.data = data }
  func rateLimits(executable: String, configDir: String) async throws -> Data {
    directory = configDir
    return data
  }
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
}
