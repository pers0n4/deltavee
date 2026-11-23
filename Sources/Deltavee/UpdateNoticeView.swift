import DeltaveeCore
import SwiftUI

/// Opens the validated release page without downloading or installing the update.
struct UpdateNoticeView: View {
  let release: ReleaseUpdate
  var body: some View {
    Link(destination: release.releaseURL) {
      Text(
        "View Deltavee \(release.version.description) on GitHub \(Image(systemName: "arrow.up.right"))"
      )
      .font(.caption)
      .foregroundStyle(Color.accentColor)
      .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(.plain)
    .help("Open the official release page in your browser. Download and install manually.")
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct UpdateCheckFeedbackView: View {
  let status: UpdateStatus

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      if status.isChecking {
        ProgressView().controlSize(.mini).accessibilityHidden(true)
      }
      Text(Self.statusMessage(for: status))
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func statusMessage(for status: UpdateStatus) -> String {
    switch status {
    case .idle: "Updates have not been checked."
    case .checking: "Checking for updates…"
    case .current(let version): "Deltavee \(version) is up to date."
    case .available: ""
    case .unavailable(.configuration):
      "Updates are unavailable in this build. Install a bundled release to check for updates."
    case .unavailable(.noRelease):
      "No published release is available yet. Check again later."
    case .unavailable(.network):
      "Couldn’t check for updates. Check your connection and try again."
    case .unavailable(.http(429)):
      "GitHub is limiting update checks. Try again later."
    case .unavailable(.http(let status)) where (500...599).contains(status):
      "GitHub is unavailable. Try again later."
    case .unavailable(.http):
      "GitHub couldn’t provide a release. Try again later."
    case .unavailable(.invalidResponse), .unavailable(.responseTooLarge):
      "GitHub returned an invalid release. Try again later."
    case .unavailable(.cancelled):
      "The update check was cancelled. Try again."
    }
  }
}
