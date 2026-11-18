import CoreFoundation
import Foundation

public struct CodexAppServerCollector: Collector {
  private static let weeklyMinutes = 10080
  private let transport: any CodexRPCTransport
  private let clock: any UsageClock
  private let executable: @Sendable () -> String?
  public init(
    transport: any CodexRPCTransport = LiveCodexRPCTransport(),
    clock: any UsageClock = SystemClock(),
    executable: @escaping @Sendable () -> String? = { Executables.resolveCodex() }
  ) {
    self.transport = transport
    self.clock = clock
    self.executable = executable
  }
  public func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    guard let executable = executable() else { return .failure(CollectError(.binaryNotFound)) }
    do {
      let data = try await transport.rateLimits(
        executable: executable, configDir: account.expandedDirectory)
      return .success(CollectedUsage(try Self.parse(data, now: clock.now())))
    } catch let error as CollectError { return .failure(error) } catch {
      return .failure(CollectError(.process))
    }
  }
  public static func parse(_ data: Data, now: Date) throws -> QuotaSnapshot {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CollectError(.schema)
    }
    // app-server reports a missing login as a JSON-RPC error, not an HTTP status. Observed 2026-11-15 with
    // codex-cli 0.167.0 and an empty `CODEX_HOME`: code -32600, message "codex account authentication
    // required to read rate limits". The `auth` match covers it; the other words and code 401 are guesses
    // for other wordings, and any other error stays `.process`.
    if let error = root["error"] as? [String: Any] {
      let text = (error["message"] as? String ?? "").lowercased()
      let code = error["code"] as? Int
      if code == 401 || text.contains("auth") || text.contains("log in") || text.contains("login")
        || text.contains("logged in")
      {
        throw CollectError(.authRequired)
      }
      throw CollectError(.process)
    }
    guard let result = root["result"] as? [String: Any],
      let limits = result["rateLimits"] as? [String: Any]
    else { throw CollectError(.schema) }
    // The weekly window is identified by length, not by slot. Verified 2026-11-15 against two accounts
    // (codex-cli 0.167.0): `primary` is the 10080-minute window and `secondary` is null.
    // Windows of any other length are ignored.
    // App-server contract: https://learn.chatgpt.com/docs/app-server#auth-endpoints
    var weekly: (used: Double, resetsAt: Date?)?
    for key in ["primary", "secondary"] {
      guard let value = limits[key] as? [String: Any],
        value["windowDurationMins"] as? Int == Self.weeklyMinutes
      else { continue }
      // An invalid weekly value is a failure so the last good value is kept.
      guard let used = Parsing.percent(value["usedPercent"]) else { throw CollectError(.schema) }
      if weekly == nil { weekly = (used, Parsing.epoch(value["resetsAt"])) }
    }
    let identity = (result["accountId"] as? String) ?? (root["accountId"] as? String)
    return QuotaSnapshot(
      weeklyUsedPercent: weekly?.used, weeklyResetsAt: weekly?.resetsAt, observedAt: now,
      fetchedAt: now, source: .codexAppServer, identityFingerprint: identity.map(Paths.fingerprint))
  }
}

enum Parsing {
  static func percent(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let value = number.doubleValue
    return value.isFinite && (0...100).contains(value) ? value : nil
  }
  static func epoch(_ value: Any?) -> Date? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite
    else { return nil }
    return Date(timeIntervalSince1970: number.doubleValue)
  }
  static func isoDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}
