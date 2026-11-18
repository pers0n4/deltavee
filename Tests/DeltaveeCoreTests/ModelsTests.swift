import XCTest

@testable import DeltaveeCore

final class ModelsTests: CoreTestCase {
  func testStaleBoundary59And61Minutes() {
    XCTAssertFalse(snapshot(observedAt: now.addingTimeInterval(-59 * 60)).isStale(now: now))
    XCTAssertFalse(snapshot(observedAt: now.addingTimeInterval(-3600)).isStale(now: now))
    XCTAssertTrue(snapshot(observedAt: now.addingTimeInterval(-61 * 60)).isStale(now: now))
  }
  func testEveryRefreshIntervalStaysBelowStaleThreshold() {
    XCTAssertEqual(QuotaSnapshot.staleAfter, 3600)
    XCTAssertTrue(Settings.intervalChoices.allSatisfy { $0 < QuotaSnapshot.staleAfter })
  }
  func testFailurePreservesLastValueAndObservation() {
    var a = account()
    let previous = snapshot(observedAt: now.addingTimeInterval(-500))
    let state = StateReducer.applying(
      .failure(CollectError(.rateLimited)), to: .ok(previous), account: &a)
    XCTAssertEqual(state, .failed(.rateLimited, lastSuccess: previous))
    XCTAssertEqual(state.lastSuccess?.observedAt, previous.observedAt)
  }
  func testNeverSuccessfulFailureDisplaysDash() {
    var a = account()
    let state = StateReducer.applying(
      .failure(CollectError(.schema)), to: .neverFetched, account: &a)
    XCTAssertNil(state.lastSuccess)
    XCTAssertEqual(
      IconRenderer.parts(accounts: [a], states: [a.id: state], mode: .used, now: now).first?.text,
      "Test --!")
  }
  func testElapsedResetDoesNotInferZero() {
    let value = snapshot()
    let a = account()
    XCTAssertLessThan(value.weeklyResetsAt!, now)
    XCTAssertEqual(
      IconRenderer.parts(accounts: [a], states: [a.id: .ok(value)], mode: .used, now: now).first?
        .text, "Test 64%")
  }
  func testIdentityChangeQuarantinesNewObservation() {
    var a = account()
    a.identityFingerprint = Paths.fingerprint("fake-old")
    let old = snapshot(fingerprint: a.identityFingerprint)
    let new = snapshot(used: 2, fingerprint: Paths.fingerprint("fake-new"))
    let state = StateReducer.applying(.success(CollectedUsage(new)), to: .ok(old), account: &a)
    XCTAssertEqual(state, .identityChanged(lastSuccess: old))
    XCTAssertEqual(a.identityFingerprint, old.identityFingerprint)
    let stillQuarantined = StateReducer.applying(
      .success(CollectedUsage(new)), to: state, account: &a)
    XCTAssertEqual(stillQuarantined.lastSuccess, old)
  }
  func testFirstIdentityAdopted() {
    var a = account()
    let value = snapshot(fingerprint: Paths.fingerprint("fake-first"))
    XCTAssertEqual(
      StateReducer.applying(.success(CollectedUsage(value)), to: .neverFetched, account: &a),
      .ok(value))
    XCTAssertEqual(a.identityFingerprint, value.identityFingerprint)
  }
  func testAcceptIdentityClearsHistoryBeforeNewSuccess() {
    var a = account()
    a.identityFingerprint = Paths.fingerprint("fake-old")
    let next = snapshot(used: 4, fingerprint: Paths.fingerprint("fake-new"))
    let cleared = StateReducer.acceptIdentity(next.identityFingerprint!, account: &a)
    XCTAssertEqual(cleared, .neverFetched)
    XCTAssertNil(cleared.lastSuccess)
    XCTAssertEqual(a.identityFingerprint, next.identityFingerprint)
    XCTAssertEqual(
      StateReducer.applying(.success(CollectedUsage(next)), to: cleared, account: &a), .ok(next))
  }
  func testNewerFallbackPromotesObservationButKeepsAuthFailure() {
    var a = account()
    let old = snapshot(observedAt: now.addingTimeInterval(-500))
    let new = snapshot(observedAt: now.addingTimeInterval(-200), used: 72)
    let state = StateReducer.applying(
      .failure(CollectError(.authRequired, fallback: new)), to: .ok(old), account: &a)
    XCTAssertEqual(state, .authRequired(lastSuccess: new))
    XCTAssertTrue(state.showsCLICommand)
  }
  func testTokenExpiryKeepsItsOwnStateAndNewerFallback() {
    var a = account()
    let old = snapshot(observedAt: now.addingTimeInterval(-500))
    let new = snapshot(observedAt: now.addingTimeInterval(-200), used: 72)
    let state = StateReducer.applying(
      .failure(CollectError(.tokenExpired, fallback: new)), to: .ok(old), account: &a)
    XCTAssertEqual(state, .tokenExpired(lastSuccess: new))
    XCTAssertTrue(state.showsCLICommand)
    XCTAssertTrue(state.hasFailure)
    XCTAssertFalse(AccountState.failed(.transport, lastSuccess: nil).showsCLICommand)
  }
  func testOlderFallbackCannotOverwriteLastSuccess() {
    var a = account()
    let old = snapshot()
    let fallback = snapshot(observedAt: now.addingTimeInterval(-7200), used: 1)
    let state = StateReducer.applying(
      .failure(CollectError(.schema, fallback: fallback)), to: .ok(old), account: &a)
    XCTAssertEqual(state, .failed(.schema, lastSuccess: old))
  }
  func testIconUsedRemainingStaleFailureAndNoFiveHour() {
    var a = account()
    a.name = "Claude"
    let hidden = Account(name: "Hidden", provider: .openai, configDir: "/fake", showInIcon: false)
    let state = AccountState.failed(
      .rateLimited, lastSuccess: snapshot(observedAt: now.addingTimeInterval(-7200), used: 64))
    XCTAssertEqual(
      IconRenderer.parts(accounts: [a, hidden], states: [a.id: state], mode: .used, now: now),
      [
        IconPart(
          provider: a.provider, accountName: "Claude", usageText: "64%!", stale: true,
          weeklyUsedPercent: 64)
      ])
    let remaining = IconRenderer.parts(
      accounts: [a], states: [a.id: state], mode: .remaining, now: now
    ).first
    XCTAssertEqual(remaining?.text, "Claude 36%!")
    let staleOnly = IconRenderer.parts(
      accounts: [a],
      states: [a.id: .ok(snapshot(observedAt: now.addingTimeInterval(-7200), used: 64))],
      mode: .used, now: now
    ).first
    XCTAssertEqual(staleOnly?.usageText, "64%", "Staleness without failure adds no marker")
    XCTAssertEqual(staleOnly?.stale, true)
    let freshFailure = IconRenderer.parts(
      accounts: [a],
      states: [
        a.id: .failed(.rateLimited, lastSuccess: snapshot(observedAt: now, used: 64))
      ],
      mode: .used, now: now
    ).first
    XCTAssertEqual(freshFailure?.usageText, "64%!")
    XCTAssertEqual(freshFailure?.stale, false)
    // Severity color input stays the actual consumption even in remaining mode.
    XCTAssertEqual(remaining?.weeklyUsedPercent, 64)
  }
  func testStaleBoundaryChangesColorFlagButNotMarker() {
    var a = account()
    a.name = "Claude"
    func part(age: TimeInterval) -> IconPart? {
      IconRenderer.parts(
        accounts: [a],
        states: [a.id: .ok(snapshot(observedAt: now.addingTimeInterval(-age), used: 64))],
        mode: .used, now: now
      ).first
    }
    let older = QuotaSnapshot.staleAfter + 1
    XCTAssertGreaterThan(older, QuotaSnapshot.staleAfter, "The stale case must exceed the boundary")
    XCTAssertEqual(part(age: QuotaSnapshot.staleAfter)?.stale, false)
    XCTAssertEqual(part(age: older)?.stale, true)
    XCTAssertEqual(part(age: QuotaSnapshot.staleAfter)?.usageText, "64%")
    XCTAssertEqual(part(age: older)?.usageText, "64%")
  }
  func testOlderSuccessKeepsLatestObservationInOKState() {
    var a = account()
    let current = snapshot()
    let older = snapshot(observedAt: now.addingTimeInterval(-7200), used: 1)
    XCTAssertEqual(
      StateReducer.applying(.success(CollectedUsage(older)), to: .ok(current), account: &a),
      .ok(current))
  }
  func testRestoredIdentityLeavesQuarantineWithoutResettingHistory() {
    var a = account()
    a.identityFingerprint = Paths.fingerprint("fake-original")
    let current = snapshot(fingerprint: a.identityFingerprint)
    let restored = snapshot(
      observedAt: now.addingTimeInterval(-20), used: 1, fingerprint: a.identityFingerprint)
    let quarantined = AccountState.identityChanged(lastSuccess: current)
    XCTAssertEqual(
      StateReducer.applying(.success(CollectedUsage(restored)), to: quarantined, account: &a),
      .ok(current))
    XCTAssertEqual(
      StateReducer.applying(
        .failure(CollectError(.rateLimited, fallback: restored)), to: quarantined, account: &a),
      .failed(.rateLimited, lastSuccess: current))
    XCTAssertEqual(
      StateReducer.applying(.failure(CollectError(.transport)), to: quarantined, account: &a),
      quarantined)
    XCTAssertEqual(a.identityFingerprint, current.identityFingerprint)
  }
  func testSignInCommandsDistinguishDefaultAndScopedDirectories() {
    XCTAssertEqual(
      Account(name: "Test", provider: .anthropic, configDir: "~/.claude/").signInCommand,
      "claude (run without CLAUDE_CONFIG_DIR)")
    XCTAssertEqual(
      Account(name: "Test", provider: .openai, configDir: "~/.codex/").signInCommand, "codex login")
    XCTAssertEqual(
      Account(name: "Test", provider: .anthropic, configDir: "/tmp/fake account/").signInCommand,
      "CLAUDE_CONFIG_DIR='/tmp/fake account' claude")
    XCTAssertEqual(
      Account(name: "Test", provider: .openai, configDir: "/tmp/fake'account/").signInCommand,
      "CODEX_HOME='/tmp/fake'\\''account' codex login")
  }
  func testFailureMessagesAreEnglishWithAndWithoutPreviousUsage() {
    let cases: [(FailureKind, String)] = [
      (.binaryNotFound, "CLI not found"),
      (.schema, "Invalid response format"),
      (.rateLimited, "Rate limited"),
      (.http(403), "HTTP error 403"),
      (.http(503), "HTTP error 503"),
      (.timeout, "Response timed out"),
      (.process, "CLI execution error"),
      (.transport, "Connection error"),
      (.authRequired, "Sign-in required"),
      (.tokenExpired, "Token expired"),
      (.statuslineMissing, "Statusline hook not installed or no data"),
    ]
    let previousSnapshots: [QuotaSnapshot?] = [nil, snapshot()]
    for previous in previousSnapshots {
      for (kind, expected) in cases {
        XCTAssertEqual(AccountState.failed(kind, lastSuccess: previous).message, expected)
      }
      XCTAssertEqual(
        AccountState.authRequired(lastSuccess: previous).message,
        "Sign-in required. Run this command in Terminal:")
      XCTAssertEqual(
        AccountState.tokenExpired(lastSuccess: previous).message,
        "Token expired — run claude to refresh:")
      XCTAssertEqual(
        AccountState.identityChanged(lastSuccess: previous).message,
        "Account change detected — use the new account to continue")
    }
  }
}
