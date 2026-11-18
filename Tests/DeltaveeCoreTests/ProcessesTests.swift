import XCTest

@testable import DeltaveeCore

final class ProcessesTests: CoreTestCase {
  func testGenericExecutableResolutionFindsLocalBinWithoutShellPATH() throws {
    let home = try temporaryDirectory()
    let bin = home.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["codex", "claude"] {
      let executable = bin.appendingPathComponent(name)
      try Data("test executable; never launched".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
      XCTAssertEqual(
        Executables.resolve(name, home: home.path, path: "/usr/bin:/bin"), executable.path)
      XCTAssertNil(
        Executables.resolve(name, home: home.appendingPathComponent("missing").path, path: ""))
    }
    XCTAssertNil(
      Executables.resolveCodex(
        configured: home.appendingPathComponent("missing-codex").path, home: home.path,
        path: bin.path))
    let configured = bin.appendingPathComponent("claude").path
    XCTAssertEqual(
      Executables.resolveCodex(configured: configured, home: home.path, path: ""), configured)
    XCTAssertEqual(
      Executables.resolve("codex", preferred: [configured], home: home.path, path: ""), configured)
  }
  func testLiveRunnerUsesRequestedWorkingDirectory() async throws {
    let directory = try temporaryDirectory()
    let output = try await LiveCommandRunner().run(
      executable: "/bin/pwd", arguments: ["-P"], environment: [:], currentDirectory: directory,
      timeout: 5)
    // `pwd -P` reports the physical path (`/private/var/...`), so compare against realpath.
    let physical = try XCTUnwrap(realpath(directory.path, nil))
    defer { free(physical) }
    XCTAssertEqual(
      String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
      String(cString: physical))
  }
  private func rpcFixture(mode: String) throws -> (URL, URL) {
    let directory = try temporaryDirectory().appendingPathComponent(mode)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let executable = directory.appendingPathComponent("fake-rpc")
    let fixture = try XCTUnwrap(
      Bundle.module.url(forResource: "fake-rpc", withExtension: "sh", subdirectory: "Fixtures"))
    try FileManager.default.copyItem(at: fixture, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return (directory, executable)
  }
  func testRPCClosesStdinAndAllowsNaturalExit() async throws {
    let (directory, executable) = try rpcFixture(mode: "natural")
    let data = try await LiveCodexRPCTransport().rateLimits(
      executable: executable.path, configDir: directory.path)
    XCTAssertEqual(try CodexAppServerCollector.parse(data, now: now).weeklyUsedPercent, 31)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("eof").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("term").path))
  }
  func testRPCGraceThenTERMAllowsCleanup() async throws {
    let (directory, executable) = try rpcFixture(mode: "term")
    let start = ProcessInfo.processInfo.systemUptime
    _ = try await LiveCodexRPCTransport().rateLimits(
      executable: executable.path, configDir: directory.path)
    XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 3)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("term").path))
  }
  func testRPCIgnoresTERMAndIsKilledAfterGrace() async throws {
    let (directory, executable) = try rpcFixture(mode: "kill")
    let start = ProcessInfo.processInfo.systemUptime
    _ = try await LiveCodexRPCTransport().rateLimits(
      executable: executable.path, configDir: directory.path)
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    XCTAssertGreaterThanOrEqual(elapsed, 4)
    XCTAssertLessThan(elapsed, 10)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("eof").path))
  }
  func testCommandDeadlineEscalatesTERMToKILL() async {
    let start = ProcessInfo.processInfo.systemUptime
    do {
      _ = try await LiveCommandRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "trap '' TERM; while :; do /bin/sleep 0.05; done"], timeout: 0.2)
      XCTFail("Expected timeout")
    } catch { XCTAssertEqual((error as? CollectError)?.kind, .timeout) }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    XCTAssertGreaterThanOrEqual(elapsed, 1.2)
    XCTAssertLessThan(elapsed, 5)
  }
  func testRPCDeadlineRemainsTwentySecondsAndEscalates() async throws {
    let (directory, executable) = try rpcFixture(mode: "deadline")
    let start = ProcessInfo.processInfo.systemUptime
    do {
      _ = try await LiveCodexRPCTransport().rateLimits(
        executable: executable.path, configDir: directory.path)
      XCTFail("Expected timeout")
    } catch { XCTAssertEqual((error as? CollectError)?.kind, .timeout) }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    XCTAssertGreaterThanOrEqual(elapsed, 21)
    XCTAssertLessThan(elapsed, 26)
  }
  func testVersionCommandDoesNotInheritClaudeConfigEnvironment() async throws {
    let (_, executable) = try rpcFixture(mode: "version")
    setenv("CLAUDE_CONFIG_DIR", "/fake/account", 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    let output = try await LiveCommandRunner().run(
      executable: executable.path, arguments: ["--version"], environment: [:], timeout: 5)
    XCTAssertEqual(output.status, 0)
    XCTAssertEqual(String(data: output.data, encoding: .utf8), "2.1.0 (Claude Code)\n")
  }
  func testChildEnvironmentDropsInheritedAccountScopeButKeepsExplicit() {
    let inherited = ["PATH": "/bin", "CLAUDE_CONFIG_DIR": "/fake/a", "CODEX_HOME": "/fake/b"]
    XCTAssertEqual(ProcessEnvironment.child(explicit: [:], inherited: inherited), ["PATH": "/bin"])
    XCTAssertEqual(
      ProcessEnvironment.child(explicit: ["CODEX_HOME": "/fake/c"], inherited: inherited),
      ["PATH": "/bin", "CODEX_HOME": "/fake/c"])
  }
  func testChildEnvironmentKeepsOnlyAllowlistedInheritedValues() {
    let kept = [
      "PATH": "/bin", "HOME": "/fake/home", "USER": "user", "LOGNAME": "user", "SHELL": "/bin/zsh",
      "TMPDIR": "/fake/tmp", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
      "LC_CTYPE": "UTF-8", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
      "HTTPS_PROXY": "http://proxy:8080", "no_proxy": "localhost",
    ]
    let dropped = [
      "ANTHROPIC_API_KEY": "key", "ANTHROPIC_AUTH_TOKEN": "token",
      "CLAUDE_CODE_OAUTH_TOKEN": "token", "ANTHROPIC_BASE_URL": "https://example.invalid",
      "OPENAI_API_KEY": "key", "OPENAI_BASE_URL": "https://example.invalid",
      "CLAUDE_CONFIG_DIR": "/fake/a", "CODEX_HOME": "/fake/b", "NODE_OPTIONS": "--require x",
    ]
    let inherited = kept.merging(dropped) { first, _ in first }
    XCTAssertEqual(ProcessEnvironment.child(explicit: [:], inherited: inherited), kept)
    // An explicit value always wins, including a key outside the allowlist.
    XCTAssertEqual(
      ProcessEnvironment.child(
        explicit: ["CLAUDE_CONFIG_DIR": "/fake/c", "PATH": "/usr/bin"], inherited: inherited),
      kept.merging(["CLAUDE_CONFIG_DIR": "/fake/c", "PATH": "/usr/bin"]) { _, new in new })
  }
}
