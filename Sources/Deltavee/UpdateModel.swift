import DeltaveeCore
import Foundation
import Observation

@MainActor
@Observable
final class UpdateModel {
  private(set) var state: UpdateState
  private var hasRequestedCheck: Bool
  var manualFeedback: UpdateStatus? {
    guard hasRequestedCheck else { return nil }
    if case .available = state.status { return nil }
    return state.status
  }
  @ObservationIgnored private let checker: UpdateChecker
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var startupTask: Task<Void, Never>?
  @ObservationIgnored private var stopped = false

  /// Inject an initial state for host rendering without starting HTTP, timers, or account collection.
  init(
    checker: UpdateChecker? = nil, initialState: UpdateState = UpdateState(),
    hasRequestedCheck: Bool = false
  ) {
    self.checker =
      checker ?? UpdateChecker(configuration: Self.configuration(info: Bundle.main.infoDictionary))
    state = initialState
    self.hasRequestedCheck = hasRequestedCheck
  }

  static func configuration(info: [String: Any]?) -> Result<UpdateConfiguration, UpdateFailure> {
    do {
      return .success(
        try UpdateConfiguration(
          version: info?["CFBundleShortVersionString"] as? String,
          repository: info?["DeltaveeUpdateRepository"] as? String))
    } catch { return .failure(.configuration) }
  }

  func start() {
    guard startupTask == nil, !stopped else { return }
    observe()
    let checker = checker
    startupTask = Task {
      guard !Task.isCancelled else { return }
      await checker.start()
    }
  }

  func checkNow() async {
    guard !stopped else { return }
    hasRequestedCheck = true
    observe()
    _ = await checker.checkNow()
  }

  func dismissManualFeedback() {
    hasRequestedCheck = false
  }

  /// Drains the cancelled request before application termination, including its final safe log entry.
  func stop() async {
    stopped = true
    startupTask?.cancel()
    observationTask?.cancel()
    await checker.stop()
    await startupTask?.value
    await observationTask?.value
    startupTask = nil
    observationTask = nil
  }

  private func observe() {
    guard observationTask == nil else { return }
    let updates = checker.updates
    observationTask = Task { [weak self] in
      for await state in updates {
        guard !Task.isCancelled else { return }
        self?.state = state
      }
    }
  }
}
