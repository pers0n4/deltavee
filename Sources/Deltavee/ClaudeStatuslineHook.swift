import Foundation

// The bundled script and the installed copy share a name, but Claude runs only the installed copy.
enum ClaudeStatuslineHook {
  static let filename = "claude-statusline-capture.sh"

  static func refresh(bundled: URL, installed: URL) throws {
    let files = FileManager.default
    let attributes: [FileAttributeKey: Any]?
    do {
      attributes = try files.attributesOfItem(atPath: installed.path)
    } catch let error as CocoaError
      where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    {
      attributes = nil
    }
    if let attributes, attributes[.type] as? FileAttributeType != .typeRegular { return }

    let script = try Data(contentsOf: bundled)
    if attributes != nil, try script == Data(contentsOf: installed) { return }

    let directory = installed.deletingLastPathComponent()
    if attributes == nil {
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Stage the executable before making it visible at the path Claude runs.
    let staging = try files.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
    defer { try? files.removeItem(at: staging) }
    let replacement = staging.appendingPathComponent(filename)
    try script.write(to: replacement)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
    if attributes == nil {
      try files.moveItem(at: replacement, to: installed)
    } else {
      _ = try files.replaceItemAt(
        installed, withItemAt: replacement, options: .usingNewMetadataOnly)
    }
  }
}
