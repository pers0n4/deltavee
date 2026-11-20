import Darwin
import Foundation

public struct CommandOutput: Sendable {
  public let status: Int32
  public let data: Data
  public init(status: Int32, data: Data) {
    self.status = status
    self.data = data
  }
}
public protocol CommandRunning: Sendable {
  /// `currentDirectory` nil inherits the app's working directory.
  func run(
    executable: String, arguments: [String], environment: [String: String],
    currentDirectory: URL?, timeout: TimeInterval
  ) async throws -> CommandOutput
}
extension CommandRunning {
  public func run(
    executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
  ) async throws -> CommandOutput {
    try await run(
      executable: executable, arguments: arguments, environment: environment,
      currentDirectory: nil, timeout: timeout)
  }
}
public protocol CodexRPCTransport: Sendable {
  func rateLimits(executable: String, configDir: String) async throws -> Data
}

// This owner serializes termination from the deadline/cancellation handler with process startup.
private final class ProcessOwner: @unchecked Sendable {
  let process = Process()
  private let lock = NSLock()
  private var stopped = false
  func launch() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { throw CollectError(.timeout) }
    try process.run()
  }
  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    stopped = true
    if process.isRunning { kill(process.processIdentifier, SIGTERM) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.signal(SIGKILL) }
  }
  private func signal(_ signal: Int32) {
    lock.lock()
    defer { lock.unlock() }
    if process.isRunning { kill(process.processIdentifier, signal) }
  }
  /// Waits up to `grace` for a normal exit, then sends SIGTERM and, one second later, SIGKILL.
  /// `codex app-server` gets a chosen 3-second grace for a possible credential flush, not a measured
  /// completion bound. App-server uses CLI-managed login: https://learn.chatgpt.com/docs/app-server#auth-endpoints
  func shutdown(grace: TimeInterval) {
    guard process.processIdentifier > 0 else { return }
    let end = ProcessInfo.processInfo.systemUptime + grace
    while process.isRunning && !timedOut && ProcessInfo.processInfo.systemUptime < end {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      signal(SIGTERM)
      let terminationEnd = ProcessInfo.processInfo.systemUptime + 1
      while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationEnd {
        Thread.sleep(forTimeInterval: 0.01)
      }
      signal(SIGKILL)
    }
    process.waitUntilExit()
  }
  var timedOut: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}

private enum ProcessIO {
  static func blocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws
    -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        do { continuation.resume(returning: try operation()) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  static func read(_ handle: FileHandle, count: Int, owner: ProcessOwner) throws -> Data {
    var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
    while true {
      if owner.timedOut { throw CollectError(.timeout) }
      let ready = poll(&descriptor, 1, 100)
      if ready < 0 {
        if errno == EINTR { continue }
        throw CollectError(.process)
      }
      if ready == 0 { continue }
      var bytes = [UInt8](repeating: 0, count: count)
      let size = Darwin.read(handle.fileDescriptor, &bytes, count)
      if size < 0 {
        if errno == EINTR { continue }
        throw CollectError(.process)
      }
      return Data(bytes.prefix(size))
    }
  }
}

// The serial queue owns stderr reads and the diagnostic prefix. The source closes the
// read handle on that queue after its last event, so cancellation cannot race a read.
private final class CodexStartupStderr: @unchecked Sendable {
  // Verified with macOS /usr/bin/env on 2026-11-20: missing Node prints this line.
  private static let missingNode = "env: node: No such file or directory\n"
  let pipe: Pipe
  private let queue = DispatchQueue(label: "dev.pers0n4.deltavee.codex-stderr")
  private let source: DispatchSourceRead
  private var prefix = Data()
  private var finished = false

  init?() {
    let pipe = Pipe()
    let reader = pipe.fileHandleForReading
    let fd = reader.fileDescriptor
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
    self.pipe = pipe
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.drain(fd) }
    source.setCancelHandler { try? reader.close() }
    source.activate()
  }

  deinit { source.cancel() }

  var nodeNotFound: Bool {
    queue.sync {
      if !finished { drain(pipe.fileHandleForReading.fileDescriptor) }
      return prefix.elementsEqual(Self.missingNode.utf8)
    }
  }

  private func drain(_ fd: Int32) {
    guard !finished else { return }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4096) { bytes in
      let count = Darwin.read(fd, bytes.baseAddress, bytes.count)
      if count > 0 {
        let remaining = Self.missingNode.utf8.count - prefix.count
        prefix.append(contentsOf: bytes.prefix(min(count, remaining)))
      } else if count == 0 {
        finished = true
        source.cancel()
      }
    }
  }
}

/// Child CLIs inherit only an allowlist of the app's environment, so credentials and endpoint overrides
/// from a launching shell (for example `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
/// `OPENAI_API_KEY`) never switch a CLI away from the account's stored login. Account-scoped directories
/// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) are passed only explicitly.
public enum ProcessEnvironment {
  /// System, locale, and network proxy variables a CLI needs to start and reach its service.
  public static let inheritedKeys: Set<String> = [
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING",
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
  ]
  public static func child(
    explicit: [String: String], inherited: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    let base = inherited.filter { inheritedKeys.contains($0.key) || $0.key.hasPrefix("LC_") }
    return base.merging(explicit) { _, new in new }
  }

  fileprivate static func child(explicit: [String: String], launchURL: URL) -> [String: String] {
    var environment = child(explicit: explicit)
    // npm launchers can be symlinks. The interpreter may live beside the link, not its target.
    let launchDirectory = launchURL.deletingLastPathComponent().path
    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = path.isEmpty ? launchDirectory : "\(path):\(launchDirectory)"
    return environment
  }
}

public struct LiveCommandRunner: CommandRunning {
  public init() {}
  public func run(
    executable: String, arguments: [String], environment: [String: String] = [:],
    currentDirectory: URL? = nil, timeout: TimeInterval = 20
  ) async throws -> CommandOutput {
    let owner = ProcessOwner()
    return try await withTaskCancellationHandler {
      try await ProcessIO.blocking {
        let output = Pipe()
        let launchURL = URL(fileURLWithPath: executable)
        owner.process.executableURL = launchURL
        owner.process.arguments = arguments
        owner.process.environment = ProcessEnvironment.child(
          explicit: environment, launchURL: launchURL)
        if let currentDirectory { owner.process.currentDirectoryURL = currentDirectory }
        owner.process.standardOutput = output
        owner.process.standardError = FileHandle.nullDevice
        owner.process.standardInput = FileHandle.nullDevice
        let deadline = DispatchWorkItem { owner.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
          owner.shutdown(grace: 0)
          deadline.cancel()
          try? output.fileHandleForReading.close()
        }
        try owner.launch()
        var data = Data()
        while true {
          let chunk = try ProcessIO.read(output.fileHandleForReading, count: 8192, owner: owner)
          if chunk.isEmpty { break }
          guard data.count + chunk.count <= 1_048_576 else { throw CollectError(.schema) }
          data.append(chunk)
        }
        owner.process.waitUntilExit()
        if owner.timedOut { throw CollectError(.timeout) }
        return CommandOutput(status: owner.process.terminationStatus, data: data)
      }
    } onCancel: {
      owner.stop()
    }
  }
}

public struct LiveCodexRPCTransport: CodexRPCTransport {
  public init() {}
  public func rateLimits(executable: String, configDir: String) async throws -> Data {
    let owner = ProcessOwner()
    return try await withTaskCancellationHandler {
      try await ProcessIO.blocking {
        let input = Pipe()
        let output = Pipe()
        let launchURL = URL(fileURLWithPath: executable)
        owner.process.executableURL = launchURL
        owner.process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        owner.process.environment = ProcessEnvironment.child(
          explicit: ["CODEX_HOME": configDir], launchURL: launchURL)
        owner.process.standardInput = input
        owner.process.standardOutput = output
        let stderr = CodexStartupStderr()
        if let stderr {
          owner.process.standardError = stderr.pipe
        } else {
          owner.process.standardError = FileHandle.nullDevice
        }
        let deadline = DispatchWorkItem { owner.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer { withExtendedLifetime(stderr) {} }
        defer {
          try? input.fileHandleForWriting.close()
          owner.shutdown(grace: 3)
          deadline.cancel()
          try? output.fileHandleForReading.close()
        }
        do { try owner.launch() } catch { throw CollectError(.process) }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        func send(_ object: [String: Any]) throws {
          var data = try JSONSerialization.data(withJSONObject: object)
          data.append(10)
          try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(id: Int) throws -> Data {
          var line = Data()
          var total = 0
          while true {
            let byte = try ProcessIO.read(output.fileHandleForReading, count: 1, owner: owner)
            if byte.isEmpty { break }
            total += 1
            guard total <= 1_048_576 else { throw CollectError(.schema) }
            if byte[0] == 10 {
              defer { line.removeAll(keepingCapacity: true) }
              if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["id"] as? Int == id
              {
                return line
              }
            } else {
              line.append(byte)
            }
          }
          throw CollectError(owner.timedOut ? .timeout : .process)
        }
        let initialized: Data
        do {
          try send([
            "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "deltavee", "version": "0.1.0"]],
          ])
          initialized = try response(id: 1)
        } catch {
          let kind = (error as? CollectError)?.kind ?? .process
          if kind == .process, !owner.timedOut, stderr?.nodeNotFound == true {
            throw CollectError(.codexNodeNotFound)
          }
          throw error
        }
        if let object = try JSONSerialization.jsonObject(with: initialized) as? [String: Any],
          object["error"] != nil
        {
          throw CollectError(.process)
        }
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        let data = try response(id: 2)
        try? input.fileHandleForWriting.close()
        owner.shutdown(grace: 3)
        if owner.timedOut { throw CollectError(.timeout) }
        return data
      }
    } onCancel: {
      owner.stop()
    }
  }
}

public enum Executables {
  public static func resolveClaude(
    configured: String? = nil, home: String = NSHomeDirectory(),
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
  ) -> String? {
    resolve(
      "claude", preferred: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"], home: home,
      path: path, configured: configured)
  }

  public static func resolveCodex(
    configured: String? = nil, home: String = NSHomeDirectory(),
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
  ) -> String? {
    resolve(
      "codex", preferred: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"], home: home,
      path: path, configured: configured)
  }
  public static func resolve(
    _ name: String, preferred: [String] = [], home: String = NSHomeDirectory(),
    path: String = ProcessInfo.processInfo.environment["PATH"] ?? "", configured: String? = nil
  ) -> String? {
    if let configured, !configured.isEmpty {
      let path = Paths.absolute(configured)
      return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    let local = URL(fileURLWithPath: home).appendingPathComponent(".local/bin")
      .appendingPathComponent(name).path
    let search = preferred + [local] + path.split(separator: ":").map { String($0) + "/" + name }
    return search.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
