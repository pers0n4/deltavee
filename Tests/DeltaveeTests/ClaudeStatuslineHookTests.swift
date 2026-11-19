import Foundation
import XCTest

@testable import Deltavee

final class ClaudeStatuslineHookTests: XCTestCase {
  func testRefreshReplacesInstalledHookWithExecutableBundledScript() throws {
    try withFixture { bundled, installed in
      try FileManager.default.createDirectory(
        at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("old hook".utf8).write(to: installed)

      try ClaudeStatuslineHook.refresh(bundled: bundled, installed: installed)

      XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: bundled))
      XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
    }
  }

  func testRefreshInstallsExecutableHookOnFreshLaunch() throws {
    try withFixture { bundled, installed in
      try ClaudeStatuslineHook.refresh(bundled: bundled, installed: installed)

      XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: bundled))
      XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
    }
  }

  func testRefreshLeavesSymlinkAndItsTargetUntouched() throws {
    try withFixture { bundled, installed in
      let custom = installed.deletingLastPathComponent().appendingPathComponent("custom.sh")
      try FileManager.default.createDirectory(
        at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
      let contents = Data("custom hook".utf8)
      try contents.write(to: custom)
      try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: custom)

      try ClaudeStatuslineHook.refresh(bundled: bundled, installed: installed)

      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: installed.path), custom.path)
      XCTAssertEqual(try Data(contentsOf: custom), contents)
    }
  }

  private func withFixture(_ test: (URL, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundled = directory.appendingPathComponent("bundled.sh")
    let installed = directory.appendingPathComponent("bin/claude-statusline-capture.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
    try test(bundled, installed)
  }
}
