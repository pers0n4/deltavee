import CryptoKit
import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable {
  case anthropic, openai
  public var displayName: String { self == .anthropic ? "Claude" : "Codex" }
}

public struct Account: Codable, Sendable, Identifiable, Equatable {
  public var id: UUID
  public var name: String
  public var provider: Provider
  public var configDir: String
  public var showInIcon: Bool
  public var order: Int
  public var identityFingerprint: String?
  public init(
    id: UUID = UUID(), name: String, provider: Provider, configDir: String, showInIcon: Bool = true,
    order: Int = 0, identityFingerprint: String? = nil
  ) {
    self.id = id
    self.name = name
    self.provider = provider
    self.configDir = configDir
    self.showInIcon = showInIcon
    self.order = order
    self.identityFingerprint = identityFingerprint
  }
  /// The user's label; nil when blank or the provider name.
  public var displayLabel: String? {
    let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, label.caseInsensitiveCompare(provider.displayName) != .orderedSame else {
      return nil
    }
    return label
  }
  /// The user's label, else the email the account's CLI reports.
  public func displayLabel(email: String?) -> String? { displayLabel ?? email }
  public var expandedDirectory: String { Paths.absolute(configDir) }
  /// The CLI command that signs this account in, shown under a sign-in-required state.
  /// For Claude the same command also refreshes an expired access token.
  public var signInCommand: String {
    let directory = expandedDirectory
    let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
    if provider == .anthropic {
      return directory == Paths.absolute("~/.claude")
        ? "claude (run without CLAUDE_CONFIG_DIR)" : "CLAUDE_CONFIG_DIR=\(quoted) claude"
    }
    return directory == Paths.absolute("~/.codex")
      ? "codex login" : "CODEX_HOME=\(quoted) codex login"
  }
}

/// Whether Claude Code ran with `CLAUDE_CONFIG_DIR`; this selects its Keychain item and `.claude.json`.
public enum ClaudeConfigDirVariable: Sendable, Equatable, CaseIterable { case unset, set }

public enum Paths {
  public static var applicationSupport: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/dev.pers0n4.deltavee", isDirectory: true)
  }
  public static func absolute(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
      .precomposedStringWithCanonicalMapping
  }
  public static func fingerprint(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  /// Ways Claude Code can be pointed at this directory. The default `~/.claude` is reached both without
  /// and with `CLAUDE_CONFIG_DIR`, and each way keeps its own login; any other directory needs the variable.
  public static func claudeConfigDirVariables(configDir: String) -> [ClaudeConfigDirVariable] {
    absolute(configDir) == absolute("~/.claude") ? [.unset, .set] : [.set]
  }
  /// Claude Code's Keychain service: `Claude Code-credentials` without `CLAUDE_CONFIG_DIR`, otherwise
  /// suffixed with the first 8 hex digits of SHA-256 of the NFC config directory. Verified 2026-11-15
  /// against the Claude Code 2.1.322 binary.
  public static func claudeService(configDir: String, variable: ClaudeConfigDirVariable) -> String {
    let base = "Claude Code-credentials"
    return variable == .unset ? base : base + "-" + fingerprint(absolute(configDir)).prefix(8)
  }
  /// Claude Code's `.claude.json`: in the home directory without `CLAUDE_CONFIG_DIR`, otherwise in that
  /// directory. Verified 2026-11-15 against the Claude Code 2.1.322 binary.
  public static func claudeGlobalConfig(configDir: String, variable: ClaudeConfigDirVariable) -> URL
  {
    variable == .unset
      ? URL(fileURLWithPath: absolute("~/.claude.json"))
      : URL(fileURLWithPath: absolute(configDir)).appendingPathComponent(".claude.json")
  }
  /// Environment that makes a `claude` run use the same Keychain item and `.claude.json`.
  public static func claudeEnvironment(configDir: String, variable: ClaudeConfigDirVariable)
    -> [String: String]
  {
    variable == .unset ? [:] : ["CLAUDE_CONFIG_DIR": absolute(configDir)]
  }
  /// Empty working directory for the background `claude -p` token refresh. The CLI keys its per-project
  /// state (`projects/<path>`) by this path, so a fixed app-owned location keeps that state in one
  /// recognizable entry per account, independent of how the app was launched.
  public static func claudeRefreshWorkdir(root: URL = applicationSupport) -> URL {
    root.appendingPathComponent("claude-refresh", isDirectory: true)
  }
  public static func statuslineFile(configDir: String, root: URL = applicationSupport) -> URL {
    root.appendingPathComponent("statusline", isDirectory: true).appendingPathComponent(
      String(fingerprint(absolute(configDir)).prefix(16)) + ".json")
  }
}

public protocol UsageClock: Sendable { func now() -> Date }
public struct SystemClock: UsageClock {
  public init() {}
  public func now() -> Date { Date() }
}

public enum UsageSource: String, Codable, Sendable {
  case codexAppServer, claudeOAuth, claudeStatusline
}
public struct QuotaSnapshot: Codable, Equatable, Sendable {
  public var weeklyUsedPercent: Double?
  public var weeklyResetsAt: Date?
  public var observedAt: Date
  public var fetchedAt: Date
  public var source: UsageSource
  public var identityFingerprint: String?
  /// Banked resets read in the same response as the quota; nil when that response did not report them.
  /// Never copied from another observation, so a source that cannot report them shows them as unknown.
  public var availableResets: AvailableResets?
  public init(
    weeklyUsedPercent: Double?, weeklyResetsAt: Date? = nil, observedAt: Date, fetchedAt: Date,
    source: UsageSource, identityFingerprint: String? = nil, availableResets: AvailableResets? = nil
  ) {
    self.weeklyUsedPercent = weeklyUsedPercent
    self.weeklyResetsAt = weeklyResetsAt
    self.observedAt = observedAt
    self.fetchedAt = fetchedAt
    self.source = source
    self.identityFingerprint = identityFingerprint
    self.availableResets = availableResets
  }
  /// Chosen age threshold for stale values. Every
  /// refresh interval choice in `Settings.intervalChoices` stays below it.
  public static let staleAfter: TimeInterval = 3600
  public func isStale(now: Date) -> Bool { now.timeIntervalSince(observedAt) > Self.staleAfter }
}
/// One-time usage-limit resets a provider keeps on the account until the user redeems them or they expire.
public struct AvailableResets: Codable, Equatable, Sendable {
  /// Resets the provider counts as available.
  public var count: Int
  /// Available resets the response listed with details; nil when it sent only the count. The provider
  /// may cap the list, so this can be less than `count`.
  public var listedCount: Int?
  /// Earliest expiry among the listed available resets, which is not necessarily the earliest one the
  /// account holds when the list is shorter than `count`. Nil when none listed has an expiry.
  public var earliestListedExpiry: Date?
  public init(count: Int, listedCount: Int? = nil, earliestListedExpiry: Date? = nil) {
    self.count = count
    self.listedCount = listedCount
    self.earliestListedExpiry = earliestListedExpiry
  }
  /// Whether the listed resets cover every available one, so the earliest listed expiry is the earliest held.
  public var listsAll: Bool { listedCount.map { $0 >= count } ?? false }
}
public enum FailureKind: Codable, Equatable, Sendable {
  case binaryNotFound, schema, rateLimited
  case http(Int)
  case timeout, process, transport, authRequired, statuslineMissing
  case codexNodeNotFound
  /// The stored access token passed its expiry; running the CLI refreshes it without signing in.
  case tokenExpired
}
public struct CollectError: Error, Codable, Equatable, Sendable {
  public var kind: FailureKind
  public var fallback: QuotaSnapshot?
  /// Earliest time the source may be asked again; set for rate-limited failures.
  public var retryAt: Date?
  /// Excluded from coding so the observed email is never written out; decodes as `.unknown`.
  public var email: EmailObservation = .unknown
  private enum CodingKeys: String, CodingKey { case kind, fallback, retryAt }
  public init(
    _ kind: FailureKind, fallback: QuotaSnapshot? = nil, retryAt: Date? = nil,
    email: EmailObservation = .unknown
  ) {
    self.kind = kind
    self.fallback = fallback
    self.retryAt = retryAt
    self.email = email
  }
}
/// The sign-in email an account's CLI reported during one collection, read independently of quota.
public enum EmailObservation: Equatable, Sendable {
  /// The source could not be read or answered in an unexpected form; keep the previous email.
  case unknown
  /// The source answered definitively without an email (signed out, API-key login); clear it.
  case absent
  case address(String)
  /// Trims the value and treats a blank string as no email.
  static func reported(_ value: Any?) -> EmailObservation? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return nil }
    return .address(text)
  }
}
public struct CollectedUsage: Sendable {
  public var snapshot: QuotaSnapshot
  public var email: EmailObservation
  public init(_ snapshot: QuotaSnapshot, email: EmailObservation = .unknown) {
    self.snapshot = snapshot
    self.email = email
  }
}
public protocol Collector: Sendable {
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError>
}

public enum AccountState: Codable, Equatable, Sendable {
  case neverFetched
  case ok(QuotaSnapshot)
  case failed(FailureKind, lastSuccess: QuotaSnapshot?)
  case authRequired(lastSuccess: QuotaSnapshot?)
  case tokenExpired(lastSuccess: QuotaSnapshot?)
  case identityChanged(lastSuccess: QuotaSnapshot?)
  public var lastSuccess: QuotaSnapshot? {
    switch self {
    case .neverFetched: nil
    case .ok(let value): value
    case .failed(_, let value), .authRequired(let value), .tokenExpired(let value),
      .identityChanged(let value):
      value
    }
  }
  /// States the user resolves by running the account's CLI command.
  public var showsCLICommand: Bool {
    switch self {
    case .authRequired, .tokenExpired: true
    default: false
    }
  }
  public var hasFailure: Bool {
    if case .ok = self { return false }
    if case .neverFetched = self { return false }
    return true
  }
  public var message: String {
    switch self {
    case .neverFetched: "Not fetched yet"
    case .ok: "OK"
    case .authRequired: "Sign-in required. Run this command in Terminal:"
    case .tokenExpired: "Token expired — run claude to refresh:"
    case .identityChanged: "Account change detected — use the new account to continue"
    case .failed(let kind, _):
      switch kind {
      case .binaryNotFound: "CLI not found"
      case .schema: "Invalid response format"
      case .rateLimited: "Rate limited"
      case .http(let code): "HTTP error \(code)"
      case .timeout: "Response timed out"
      case .process: "CLI execution error"
      case .codexNodeNotFound:
        "Codex cannot find Node.js. Install the standalone Codex CLI or set a working CLI path."
      case .transport: "Connection error"
      case .authRequired: "Sign-in required"
      case .tokenExpired: "Token expired"
      case .statuslineMissing: "Statusline hook not installed or no data"
      }
    }
  }
}

public enum StateReducer {
  public static func acceptIdentity(_ fingerprint: String, account: inout Account) -> AccountState {
    account.identityFingerprint = fingerprint
    return .neverFetched
  }
  public static func applying(
    _ result: Result<CollectedUsage, CollectError>, to state: AccountState, account: inout Account
  ) -> AccountState {
    let candidate: QuotaSnapshot?
    switch result {
    case .success(let value): candidate = value.snapshot
    case .failure(let error): candidate = error.fallback
    }
    // Only the stored identity returning ends quarantine; preserve its history while waiting.
    if case .identityChanged = state,
      candidate?.identityFingerprint == nil
        || candidate?.identityFingerprint != account.identityFingerprint
    {
      return state
    }
    if let old = account.identityFingerprint, let new = candidate?.identityFingerprint, old != new {
      return .identityChanged(lastSuccess: state.lastSuccess)
    }
    if account.identityFingerprint == nil, let fingerprint = candidate?.identityFingerprint {
      account.identityFingerprint = fingerprint
    }
    switch result {
    case .success(let value):
      if let previous = state.lastSuccess, previous.observedAt > value.snapshot.observedAt {
        return .ok(previous)
      }
      return .ok(value.snapshot)
    case .failure(let error):
      var last = state.lastSuccess
      if let fallback = error.fallback, last == nil || fallback.observedAt > last!.observedAt {
        last = fallback
      }
      switch error.kind {
      case .authRequired: return .authRequired(lastSuccess: last)
      case .tokenExpired: return .tokenExpired(lastSuccess: last)
      default: return .failed(error.kind, lastSuccess: last)
      }
    }
  }
}

public struct IconPart: Equatable, Sendable {
  public var provider: Provider
  public var accountName: String
  public var usageText: String
  public var stale: Bool
  /// Actual weekly consumption, independent of the used/remaining display mode.
  public var weeklyUsedPercent: Double?
  public init(
    provider: Provider, accountName: String, usageText: String, stale: Bool,
    weeklyUsedPercent: Double? = nil
  ) {
    self.provider = provider
    self.accountName = accountName
    self.usageText = usageText
    self.stale = stale
    self.weeklyUsedPercent = weeklyUsedPercent
  }
  public var text: String { "\(accountName.prefix(8)) \(usageText)" }
}
public enum IconRenderer {
  public static func percentage(_ used: Double?, mode: PercentMode) -> String {
    guard let used else { return "--" }
    return String(format: "%.0f%%", mode == .used ? used : 100 - used)
  }
  /// `emails` holds each account's detected email, shown when the account has no label.
  public static func parts(
    accounts: [Account], states: [UUID: AccountState], mode: PercentMode, now: Date,
    emails: [UUID: String] = [:]
  ) -> [IconPart] {
    accounts.filter(\.showInIcon).sorted { $0.order < $1.order }.map { account in
      let state = states[account.id] ?? .neverFetched
      let stale = state.lastSuccess?.isStale(now: now) ?? false
      // Only a failure, which needs action, gets a suffix marker. Staleness uses the visual treatment
      // and accessibility description instead.
      let marker = state.hasFailure ? "!" : ""
      return IconPart(
        provider: account.provider,
        accountName: account.displayLabel(email: emails[account.id])
          ?? account.provider.displayName,
        usageText: "\(percentage(state.lastSuccess?.weeklyUsedPercent, mode: mode))\(marker)",
        stale: stale, weeklyUsedPercent: state.lastSuccess?.weeklyUsedPercent)
    }
  }
}
