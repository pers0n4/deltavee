import XCTest

@testable import DeltaveeCore

struct FixedClock: UsageClock {
  let date: Date
  func now() -> Date { date }
}

/// Shared fixture time and builders for the DeltaveeCore test cases.
/// Not `final`: each area's test case subclasses it. It declares no tests, so XCTest runs nothing for it.
@MainActor
class CoreTestCase: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_900_007_200)
  func fixture(_ name: String) throws -> Data {
    try Data(
      contentsOf: XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
  }
  func account(_ provider: Provider = .anthropic) -> Account {
    Account(name: "Test", provider: provider, configDir: "/tmp/fake-deltavee-config")
  }
  func snapshot(observedAt: Date? = nil, used: Double? = 64, fingerprint: String? = nil)
    -> QuotaSnapshot
  {
    QuotaSnapshot(
      weeklyUsedPercent: used, weeklyResetsAt: now.addingTimeInterval(-100),
      observedAt: observedAt ?? now, fetchedAt: now, source: .claudeOAuth,
      identityFingerprint: fingerprint)
  }
  func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory
  }
}
