import Foundation

/// Allowlisted diagnostics only: no requests, response bodies, account information, or credentials.
public struct UpdateLogEntry: Codable, Equatable, Sendable {
  public enum Event: String, Codable, Sendable { case started, finished }
  public enum Trigger: String, Codable, Sendable { case automatic, manual }
  public enum Outcome: String, Codable, Sendable { case current, available, unavailable, cancelled }
  public let event: Event
  public let time: Date
  public let runID: UUID
  public let trigger: Trigger
  public let outcome: Outcome?
  public let failure: UpdateFailure?
  public let durationSeconds: Double?
  public init(
    event: Event, time: Date, runID: UUID, trigger: Trigger, outcome: Outcome? = nil,
    failure: UpdateFailure? = nil, durationSeconds: Double? = nil
  ) {
    self.event = event
    self.time = time
    self.runID = runID
    self.trigger = trigger
    self.outcome = outcome
    self.failure = failure
    self.durationSeconds = durationSeconds
  }
}

public protocol UpdateLogging: Sendable {
  func append(_ entry: UpdateLogEntry)
}

public struct UpdateLog: UpdateLogging {
  public let file: URL
  public let maxBytes: Int
  public init(directory: URL = Paths.applicationSupport, maxBytes: Int = 262_144) {
    file = directory.appendingPathComponent("update-check.log")
    self.maxBytes = maxBytes
  }
  public func append(_ entry: UpdateLogEntry) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    guard var line = try? encoder.encode(entry) else { return }
    line.append(10)
    PrivateLogFile.append(line, to: file, maxBytes: maxBytes)
  }
}
