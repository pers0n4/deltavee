import Foundation

/// A bounded, anonymous request, separate from provider credentials and sessions.
public struct BoundedUpdateHTTPTransport: UsageHTTPTransport {
  public static let maxResponseBytes = 262_144
  public init() {}
  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 20
    return configuration
  }
  public func send(_ request: URLRequest) async throws -> HTTPResult {
    guard
      request.url?.absoluteString
        == "https://api.github.com/repos/\(UpdateConfiguration.approvedRepository)/releases/latest"
    else { throw UpdateFailure.configuration }
    let session = URLSession(
      configuration: Self.configuration(), delegate: UpdateSessionDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.url == request.url else {
      throw UpdateFailure.invalidResponse
    }
    // Error bodies are neither consumed nor logged. The status alone determines the retry policy.
    guard http.statusCode == 200 else { return HTTPResult(status: http.statusCode, body: Data()) }
    guard response.expectedContentLength <= Int64(Self.maxResponseBytes) else {
      throw UpdateFailure.responseTooLarge
    }
    var data = Data()
    if response.expectedContentLength > 0 {
      data.reserveCapacity(Int(response.expectedContentLength))
    }
    for try await byte in bytes {
      guard data.count < Self.maxResponseBytes else { throw UpdateFailure.responseTooLarge }
      data.append(byte)
    }
    try Task.checkCancellation()
    return HTTPResult(status: http.statusCode, body: data)
  }
}

private final class UpdateSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // TLS retains system trust evaluation; HTTP authentication must never consult saved credentials.
    completionHandler(
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
}
