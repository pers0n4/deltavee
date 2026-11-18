import Foundation
import XCTest

@testable import DeltaveeCore

private actor ReleaseHTTPStub: UsageHTTPTransport {
  private var responses: [Result<HTTPResult, URLError>]
  private(set) var requests: [URLRequest] = []
  init(_ responses: [Result<HTTPResult, URLError>]) { self.responses = responses }
  func send(_ request: URLRequest) async throws -> HTTPResult {
    requests.append(request)
    guard !responses.isEmpty else { throw URLError(.badServerResponse) }
    return try responses.removeFirst().get()
  }
}

final class UpdatesTests: CoreTestCase {
  func testStableVersionsCompareNumericComponentsAndOnlyTagsAllowVPrefix() throws {
    XCTAssertGreaterThan(try version("1.10.0"), try version("1.9.99"))
    XCTAssertGreaterThan(try version("2.0.0"), try version("1.99.99"))
    XCTAssertEqual(StableVersion("v1.2.3", allowsTagPrefix: true), try version("1.2.3"))
    XCTAssertEqual(try version("0.1.0").description, "0.1.0")
    XCTAssertGreaterThan(
      try version("18446744073709551616.0.0"), try version("18446744073709551615.99.99"),
      "Valid numeric SemVer components have no machine-integer size limit")
    for invalid in [
      "", "1", "1.2", "01.2.3", "1.02.3", "1.2.03", "1.2.3.4", "1.2.3-beta.1",
      "1.2.3+build", " 1.2.3", "1.2.3\n", "-1.2.3", "１.2.3", "V1.2.3", "vv1.2.3",
    ] {
      XCTAssertNil(StableVersion(invalid, allowsTagPrefix: true), invalid)
    }
    XCTAssertNil(StableVersion("v1.2.3"), "A bundle version is not a release tag")
  }

  func testMissingOrUnapprovedBundleMetadataIsExplicitlyUnavailable() async throws {
    for (version, repository) in [
      (nil, nil), ("0.1.0", nil), (nil, "pers0n4/deltavee"),
      ("v0.1.0", "pers0n4/deltavee"), ("0.1.0", "attacker/deltavee"),
      ("0.1.0", "pers0n4/deltavee/../other"),
    ] as [(String?, String?)] {
      XCTAssertThrowsError(try UpdateConfiguration(version: version, repository: repository)) {
        XCTAssertEqual($0 as? UpdateFailure, .configuration)
      }
    }
    let http = ReleaseHTTPStub([])
    let result = await GitHubReleaseClient(configuration: .failure(.configuration), transport: http)
      .check()
    XCTAssertEqual(result, .unavailable(.configuration))
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty, "Invalid metadata must not produce a request")
  }

  func testReleaseLinksRejectEveryNoncanonicalOriginOrTagPath() throws {
    let official = "https://github.com/pers0n4/deltavee/releases/tag/v1.2.3"
    XCTAssertEqual(ReleaseUpdate(tag: "v1.2.3", url: official)?.releaseURL.absoluteString, official)
    XCTAssertNotNil(
      ReleaseUpdate(tag: "1.2.3", url: "https://github.com/pers0n4/deltavee/releases/tag/1.2.3"))
    for url in [
      "http://github.com/pers0n4/deltavee/releases/tag/v1.2.3",
      "https://github.com.attacker.invalid/pers0n4/deltavee/releases/tag/v1.2.3",
      "https://attacker@github.com/pers0n4/deltavee/releases/tag/v1.2.3",
      "https://github.com:443/pers0n4/deltavee/releases/tag/v1.2.3",
      "https://github.com/attacker/deltavee/releases/tag/v1.2.3",
      "https://github.com/pers0n4/deltavee/releases/tag/v1.2.3?download=1",
      "https://github.com/pers0n4/deltavee/releases/tag/v1.2.3#assets",
      "https://github.com/pers0n4/deltavee/releases/tag/%761.2.3",
      "https://github.com/pers0n4/deltavee/releases/tag/v1.2.3/../v9.0.0",
      "https://github.com/pers0n4/deltavee/releases/download/v1.2.3/Deltavee.zip",
      "javascript:alert(1)", "file:///Applications/Deltavee.app",
    ] {
      XCTAssertNil(ReleaseUpdate(tag: "v1.2.3", url: url), url)
    }
    XCTAssertNil(ReleaseUpdate(tag: "v1.2.3-beta", url: official))
    XCTAssertNil(ReleaseUpdate(tag: "../v1.2.3", url: official))
  }

  func testLatestStableRequestIsAnonymousAndUsesOfficialAPIContract() async throws {
    let http = ReleaseHTTPStub([.success(release())])
    let result = await client(http).check()
    guard case .available(let update) = result else { return XCTFail("Expected an update") }
    XCTAssertEqual(update.version, try version("1.10.0"))
    let requests = await http.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(
      request.url?.absoluteString, "https://api.github.com/repos/pers0n4/deltavee/releases/latest")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Deltavee/1.9.0")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.timeoutInterval, 20)
  }

  func testEqualAndOlderStableReleaseAreCurrentButNoReleaseIsNotCurrent() async throws {
    for tag in ["v1.9.0", "1.9.0", "v1.8.99"] {
      let result = await client(ReleaseHTTPStub([.success(release(tag: tag))])).check()
      XCTAssertEqual(result, .current(try version("1.9.0")))
    }
    let absent = await client(ReleaseHTTPStub([.success(HTTPResult(status: 404, body: Data()))]))
      .check()
    XCTAssertEqual(absent, .unavailable(.noRelease))
  }

  func testDraftPrereleaseMalformedAndMaliciousResponsesNeverMeanCurrent() async throws {
    let responses = [
      release(draft: true), release(prerelease: true), release(tag: "v2.0.0-rc.1"),
      release(url: "https://attacker.invalid/releases/tag/v1.10.0"),
      HTTPResult(status: 200, body: Data("{}".utf8)),
      HTTPResult(status: 200, body: Data("not JSON".utf8)),
      HTTPResult(
        status: 200,
        body: Data(
          #"{"tag_name":"v2.0.0","html_url":"https://github.com/pers0n4/deltavee/releases/tag/v2.0.0","draft":0,"prerelease":false}"#
            .utf8)),
    ]
    for response in responses {
      let result = await client(ReleaseHTTPStub([.success(response)])).check()
      guard case .unavailable = result else { return XCTFail("Unexpected success: \(result)") }
    }
  }

  func testResponseSizeBoundaryRejectsOversizedPayloadBeforeParsing() async throws {
    let limit = BoundedUpdateHTTPTransport.maxResponseBytes
    let valid = release().body
    let atLimit = HTTPResult(
      status: 200, body: valid + Data(repeating: 32, count: limit - valid.count))
    let overLimit = HTTPResult(status: 200, body: atLimit.body + Data([32]))
    XCTAssertEqual(atLimit.body.count, limit)
    XCTAssertGreaterThan(overLimit.body.count, limit, "The rejection fixture must exceed the cap")
    guard case .available = await client(ReleaseHTTPStub([.success(atLimit)])).check() else {
      return XCTFail("A valid response exactly at the cap must remain readable")
    }
    let rejected = await client(ReleaseHTTPStub([.success(overLimit)])).check()
    XCTAssertEqual(rejected, .unavailable(.responseTooLarge))
  }

  func testNetworkAndHTTPFailuresHaveBoundedRetryClassification() async throws {
    for (status, retryable) in [
      (429, true), (500, true), (503, true), (400, false), (403, false), (404, false), (302, false),
    ] {
      let result = await client(
        ReleaseHTTPStub([.success(HTTPResult(status: status, body: Data()))])
      ).check()
      guard case .unavailable(let failure) = result else { return XCTFail("Expected an error") }
      XCTAssertEqual(failure.isTransient, retryable, "HTTP \(status)")
    }
    let network = await client(ReleaseHTTPStub([.failure(URLError(.notConnectedToInternet))]))
      .check()
    XCTAssertEqual(network, .unavailable(.network))
    XCTAssertTrue(UpdateFailure.network.isTransient)
    XCTAssertTrue(UpdateFailure.invalidResponse.isTransient)
    XCTAssertTrue(UpdateFailure.responseTooLarge.isTransient)
    XCTAssertFalse(UpdateFailure.configuration.isTransient)
    XCTAssertFalse(UpdateFailure.noRelease.isTransient)
  }

  func testLiveTransportConfigurationStoresNoCredentialsCookiesOrCache() {
    let configuration = BoundedUpdateHTTPTransport.configuration()
    XCTAssertNil(configuration.urlCredentialStorage)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertNil(configuration.urlCache)
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 20)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
  }

  private func version(_ raw: String) throws -> StableVersion { try XCTUnwrap(StableVersion(raw)) }
  private func client(_ http: any UsageHTTPTransport) -> GitHubReleaseClient {
    GitHubReleaseClient(
      configuration: Result {
        try UpdateConfiguration(version: "1.9.0", repository: "pers0n4/deltavee")
      }
      .mapError { _ in UpdateFailure.configuration }, transport: http)
  }
  private func release(
    tag: String = "v1.10.0", draft: Bool = false, prerelease: Bool = false, url: String? = nil
  ) -> HTTPResult {
    let value: [String: Any] = [
      "tag_name": tag, "draft": draft, "prerelease": prerelease,
      "html_url": url ?? "https://github.com/pers0n4/deltavee/releases/tag/\(tag)",
    ]
    return HTTPResult(status: 200, body: try! JSONSerialization.data(withJSONObject: value))
  }
}
