import DeltaveeCore
import Foundation

// One-shot live check of the collectors without the menubar UI.
// Usage: deltavee-probe <claude|codex> <configDir>
//        deltavee-probe icon   (menubar title rendered from the app's persisted accounts.json/snapshots.json)
// Prints only percentages, times, source, and failure kind. Never prints tokens or identity values.
let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "icon" {
  do {
    let document = try AccountStore().load()
    let states = try SnapshotStore().load()
    let parts = IconRenderer.parts(
      accounts: document.accounts, states: states, mode: document.settings.mode, now: Date())
    print(parts.map(\.text).joined(separator: "  "))
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("cannot read app state\n".utf8))
    exit(1)
  }
}
guard arguments.count == 3,
  let provider = ["claude": Provider.anthropic, "codex": Provider.openai][arguments[1]]
else {
  FileHandle.standardError.write(Data("usage: deltavee-probe <claude|codex> <configDir>\n".utf8))
  exit(2)
}
let account = Account(name: "probe", provider: provider, configDir: arguments[2])
// The probe only reads; it never starts the app's background token refresh.
let collector: any Collector =
  provider == .anthropic ? ClaudeUsageCollector(refresher: nil) : CodexAppServerCollector()
func describe(_ snapshot: QuotaSnapshot) -> String {
  let formatter = ISO8601DateFormatter()
  let weekly = snapshot.weeklyUsedPercent.map { String(format: "%.1f%%", $0) } ?? "--"
  let reset = snapshot.weeklyResetsAt.map { formatter.string(from: $0) } ?? "-"
  return
    "weekly=\(weekly) resetsAt=\(reset) observedAt=\(formatter.string(from: snapshot.observedAt)) source=\(snapshot.source.rawValue) identity=\(snapshot.identityFingerprint == nil ? "absent" : "present")"
}

switch await collector.fetch(account) {
case .success(let usage):
  print("ok \(describe(usage.snapshot))")
case .failure(let error):
  print("failed kind=\(error.kind) fallback=\(error.fallback.map(describe) ?? "none")")
  exit(1)
}
