import Foundation

public struct AccountDocument: Codable, Sendable, Equatable {
  public var accounts: [Account]
  public var settings: Settings
  public init(accounts: [Account] = [], settings: Settings = Settings()) {
    self.accounts = accounts
    self.settings = settings
  }
}
public struct AccountStore: Sendable {
  public let directory: URL
  public init(directory: URL = Paths.applicationSupport) { self.directory = directory }
  public func load() throws -> AccountDocument {
    let file = directory.appendingPathComponent("accounts.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return AccountDocument() }
    return try JSONDecoder().decode(AccountDocument.self, from: Data(contentsOf: file))
  }
  public func save(_ document: AccountDocument) throws {
    try Persistence.save(document, file: directory.appendingPathComponent("accounts.json"))
  }
}
public struct SnapshotStore: Sendable {
  public let directory: URL
  public init(directory: URL = Paths.applicationSupport) { self.directory = directory }
  public func load() throws -> [UUID: AccountState] {
    let file = directory.appendingPathComponent("snapshots.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    return try JSONDecoder().decode([UUID: AccountState].self, from: Data(contentsOf: file))
  }
  public func save(_ states: [UUID: AccountState]) throws {
    // Keep the transient startup diagnostic readable by older versions of Deltavee.
    var compatible = states
    for (id, state) in states {
      if case .failed(.codexNodeNotFound, let lastSuccess) = state {
        compatible[id] = .failed(.process, lastSuccess: lastSuccess)
      }
    }
    try Persistence.save(compatible, file: directory.appendingPathComponent("snapshots.json"))
  }
}
/// Per-account time before which collection must not be retried after a rate limit.
public struct RateLimitStore: Sendable {
  public let directory: URL
  public init(directory: URL = Paths.applicationSupport) { self.directory = directory }
  public func load() throws -> [UUID: Date] {
    let file = directory.appendingPathComponent("rate-limits.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    return try JSONDecoder().decode([UUID: Date].self, from: Data(contentsOf: file))
  }
  public func save(_ holds: [UUID: Date]) throws {
    try Persistence.save(holds, file: directory.appendingPathComponent("rate-limits.json"))
  }
}
private enum Persistence {
  static func save<T: Encodable>(_ value: T, file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(value)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
