import Foundation

/// Stable numeric SemVer only. Bundle versions have no prefix; release tags may have one lowercase `v`.
public struct StableVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
  private let major: Substring
  private let minor: Substring
  private let patch: Substring
  public init?(_ text: String, allowsTagPrefix: Bool = false) {
    let value = allowsTagPrefix && text.hasPrefix("v") ? text.dropFirst() : text[...]
    guard let firstDot = value.firstIndex(of: ".") else { return nil }
    let minorStart = value.index(after: firstDot)
    guard let secondDot = value[minorStart...].firstIndex(of: ".") else { return nil }
    let major = value[..<firstDot]
    let minor = value[minorStart..<secondDot]
    let patch = value[value.index(after: secondDot)...]
    guard Self.isComponent(major), Self.isComponent(minor), Self.isComponent(patch) else {
      return nil
    }
    self.major = major
    self.minor = minor
    self.patch = patch
  }
  public var description: String { "\(major).\(minor).\(patch)" }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    let major = compare(lhs.major, rhs.major)
    if major != 0 { return major < 0 }
    let minor = compare(lhs.minor, rhs.minor)
    if minor != 0 { return minor < 0 }
    return compare(lhs.patch, rhs.patch) < 0
  }
  private static func isComponent(_ value: Substring) -> Bool {
    guard let first = value.utf8.first, first != 48 || value.utf8.count == 1 else { return false }
    return value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
  }
  /// Compare numeric digit sequences without an integer-size limit or dotted-string ordering.
  private static func compare(_ lhs: Substring, _ rhs: Substring) -> Int {
    if lhs.utf8.count != rhs.utf8.count { return lhs.utf8.count < rhs.utf8.count ? -1 : 1 }
    for (left, right) in zip(lhs.utf8, rhs.utf8) where left != right {
      return left < right ? -1 : 1
    }
    return 0
  }
}

public struct UpdateConfiguration: Sendable {
  public static let approvedRepository = "pers0n4/deltavee"
  public let currentVersion: StableVersion
  public init(version: String?, repository: String?) throws {
    guard repository == Self.approvedRepository, let version,
      let parsed = StableVersion(version)
    else { throw UpdateFailure.configuration }
    currentVersion = parsed
  }
  public var latestReleaseURL: URL {
    URL(string: "https://api.github.com/repos/\(Self.approvedRepository)/releases/latest")!
  }
}

/// The only browser destination accepted by the updater. Its immutable URL cannot name a download.
public struct ReleaseUpdate: Equatable, Sendable {
  public let version: StableVersion
  public let releaseURL: URL
  public init?(tag: String, url: String) {
    guard let version = StableVersion(tag, allowsTagPrefix: true),
      url == "https://github.com/\(UpdateConfiguration.approvedRepository)/releases/tag/\(tag)",
      let releaseURL = URL(string: url)
    else { return nil }
    self.version = version
    self.releaseURL = releaseURL
  }
}

public enum UpdateFailure: Error, Codable, Equatable, Sendable {
  case configuration, noRelease, network, invalidResponse, responseTooLarge, cancelled
  case http(Int)
  public var isTransient: Bool {
    switch self {
    case .network, .invalidResponse, .responseTooLarge: true
    case .http(let status): status == 429 || (500...599).contains(status)
    case .configuration, .noRelease, .cancelled: false
    }
  }
}

public enum UpdateStatus: Equatable, Sendable {
  case idle, checking
  case current(StableVersion)
  case available(ReleaseUpdate)
  case unavailable(UpdateFailure)
  public var isChecking: Bool { self == .checking }
}

/// Only successful checks replace the remembered release and timestamp. Failures never look current.
public struct UpdateState: Equatable, Sendable {
  public let status: UpdateStatus
  public let availableRelease: ReleaseUpdate?
  public let lastSuccessfulCheck: Date?
  public init(
    status: UpdateStatus = .idle, availableRelease: ReleaseUpdate? = nil,
    lastSuccessfulCheck: Date? = nil
  ) {
    self.status = status
    if case .available(let release) = status {
      self.availableRelease = release
    } else {
      self.availableRelease = availableRelease
    }
    self.lastSuccessfulCheck = lastSuccessfulCheck
  }
}

public struct GitHubReleaseClient: Sendable {
  private let configuration: Result<UpdateConfiguration, UpdateFailure>
  private let transport: any UsageHTTPTransport
  public init(
    configuration: Result<UpdateConfiguration, UpdateFailure>,
    transport: any UsageHTTPTransport = BoundedUpdateHTTPTransport()
  ) {
    self.configuration = configuration
    self.transport = transport
  }
  public func check() async -> UpdateStatus {
    let configuration: UpdateConfiguration
    switch self.configuration {
    case .success(let value): configuration = value
    case .failure(let failure): return .unavailable(failure)
    }
    var request = URLRequest(url: configuration.latestReleaseURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 20
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    // GitHub's public latest endpoint excludes draft/prereleases; still validate both flags and URLs.
    // Verified 2026-11-18: https://docs.github.com/en/rest/releases/releases#get-the-latest-release
    // Accept and API version follow the same official REST documentation above.
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("Deltavee/\(configuration.currentVersion)", forHTTPHeaderField: "User-Agent")
    do {
      try Task.checkCancellation()
      let response = try await transport.send(request)
      try Task.checkCancellation()
      guard response.status == 200 else {
        return .unavailable(response.status == 404 ? .noRelease : .http(response.status))
      }
      guard response.body.count <= BoundedUpdateHTTPTransport.maxResponseBytes else {
        return .unavailable(.responseTooLarge)
      }
      guard let release = try? JSONDecoder().decode(ReleaseResponse.self, from: response.body)
      else {
        return .unavailable(.invalidResponse)
      }
      guard !release.draft, !release.prerelease else { return .unavailable(.noRelease) }
      guard let update = ReleaseUpdate(tag: release.tagName, url: release.htmlURL) else {
        return .unavailable(.invalidResponse)
      }
      return update.version > configuration.currentVersion
        ? .available(update) : .current(configuration.currentVersion)
    } catch is CancellationError {
      return .unavailable(.cancelled)
    } catch let failure as UpdateFailure {
      return .unavailable(failure)
    } catch let error as URLError where error.code == .cancelled {
      return .unavailable(.cancelled)
    } catch {
      return .unavailable(.network)
    }
  }
  private struct ReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
      case draft, prerelease
    }
  }
}
