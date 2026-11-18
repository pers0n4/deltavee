import Foundation

/// The two background logs share only their private, size-bounded JSON-line file handling.
enum PrivateLogFile {
  private static let lock = NSLock()
  static func append(_ line: Data, to file: URL, maxBytes: Int) {
    guard line.count <= maxBytes else { return }
    lock.withLock {
      let manager = FileManager.default
      // Diagnostics must never prevent the background operation, even if the directory is unwritable.
      try? manager.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      if let attributes = try? manager.attributesOfItem(atPath: file.path) {
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
        guard
          (try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)) != nil
        else { return }
        if let size = attributes[.size] as? Int, size + line.count > maxBytes {
          let previous = file.appendingPathExtension("1")
          try? manager.removeItem(at: previous)
          guard (try? manager.moveItem(at: file, to: previous)) != nil else { return }
        }
      }
      if !manager.fileExists(atPath: file.path) {
        guard
          manager.createFile(
            atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { return }
      }
      guard let handle = try? FileHandle(forWritingTo: file) else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
    }
  }
}
