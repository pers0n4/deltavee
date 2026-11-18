import AppKit
import DeltaveeCore
import SwiftUI
import XCTest

@testable import Deltavee

/// Renders the README panel and menu bar screenshots from fake accounts. Skipped unless `DELTAVEE_SCREENSHOTS=1`,
/// so a normal `swift test` never rewrites `.github/images/`. Run `mise run screenshots` to regenerate.
final class ReadmeScreenshotTests: XCTestCase {
  private static let scale = 2
  /// Room around the panel image for the drop shadow, in points.
  static let margin: CGFloat = 24
  /// Smaller room around the menu bar image, so the light and dark images stacked in the README sit close together.
  static let menuBarMargin: CGFloat = 16
  private static let output = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".github/images", isDirectory: true)

  @MainActor
  func testWritesReadmePanelScreenshots() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["DELTAVEE_SCREENSHOTS"] == "1",
      "Set DELTAVEE_SCREENSHOTS=1 to write .github/images")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    populate(model)
    try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let window = makeWindow(model: model, appearance: appearance)
      defer {
        window.contentView = nil
        window.close()
      }
      try await settle(window)
      let png = try render(window, dark: appearance == .darkAqua)
      try png.write(to: Self.output.appendingPathComponent("panel-\(name).png"))
      try renderMenuBar(model, appearance: appearance).write(
        to: Self.output.appendingPathComponent("menubar-\(name).png"))
    }
  }

  /// Fixed relative times keep the images independent of the clock and time zone of the machine.
  @MainActor
  private func populate(_ model: AppModel) {
    let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
    model.now = now
    model.document.settings.resetTimeMode = .relative
    model.document.settings.updatedTimeMode = .relative
    model.document.settings.transparentPanel = false
    let minute: TimeInterval = 60
    let fakes: [(String, Provider, Double, TimeInterval, UsageSource)] = [
      ("", .anthropic, 38, 2 * 24 * 60 + 5 * 60, .claudeOAuth),
      ("Work", .anthropic, 74, 5 * 24 * 60 + 40, .claudeOAuth),
      ("", .openai, 91, 22 * 60 + 15, .codexAppServer),
    ]
    for (index, fake) in fakes.enumerated() {
      let (name, provider, weekly, resetMinutes, source) = fake
      let account = Account(
        name: name, provider: provider, configDir: "/fake/\(index)", order: index)
      model.document.accounts.append(account)
      model.states[account.id] = .ok(
        QuotaSnapshot(
          weeklyUsedPercent: weekly, weeklyResetsAt: now + resetMinutes * minute,
          observedAt: now - Double(2 + index * 3) * minute, fetchedAt: now, source: source))
    }
  }

  @MainActor
  private func makeWindow(model: AppModel, appearance: NSAppearance.Name) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 1), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = NSHostingView(
      rootView: PanelView(
        model: model, maxHeight: 1000,
        onHeightChange: { [weak window] height in
          window?.setContentSize(NSSize(width: PanelView.width, height: height))
        }))
    return window
  }

  @MainActor
  private func settle(_ window: NSWindow) async throws {
    for _ in 0..<10 {
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// Draws at a fixed 2x scale so the output does not depend on the attached display.
  @MainActor
  private func render(_ window: NSWindow, dark: Bool) throws -> Data {
    let view = try XCTUnwrap(window.contentView)
    let size = view.bounds.size
    XCTAssertGreaterThan(size.height, 100, "The panel must lay out its accounts before rendering")
    let panel = try bitmap(size: size)
    view.cacheDisplay(in: view.bounds, to: panel)
    return try framed(size: size, radius: PanelView.cornerRadius, dark: dark) { frame in
      panel.draw(in: frame)
    }
  }

  /// A menu bar strip with Deltavee's status item title, built from the same model values and
  /// title code as `AppDelegate.render()`, followed by stand-in system items and a fixed clock.
  /// The background is a gradient "wallpaper" under a translucent tint, approximating the
  /// translucent menu bar; the system items are SF Symbols, not captures of the real ones.
  @MainActor
  private func renderMenuBar(_ model: AppModel, appearance: NSAppearance.Name) throws -> Data {
    let parts = IconRenderer.parts(
      accounts: model.document.accounts, states: model.states, mode: model.document.settings.mode,
      now: model.now)
    XCTAssertEqual(parts.map(\.usageText), ["62%", "26%", "9%"])
    let title = MenuBarTitle.attributedString(
      parts: parts, colorUsage: model.document.settings.colorMenuBarUsage)
    let dark = appearance == .darkAqua
    let ink = dark ? NSColor.white : NSColor.black.withAlphaComponent(0.85)
    let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
      .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
    let symbols = try ["battery.100percent", "wifi"].map { name in
      try XCTUnwrap(
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
          .withSymbolConfiguration(symbolConfiguration), "Missing SF Symbol \(name)")
    }
    // A fixed weekday and time keep the image independent of when it is generated.
    let clock = NSAttributedString(
      string: "Tue 9:41 AM",
      attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: ink])
    let (padding, gap, height): (CGFloat, CGFloat, CGFloat) = (14, 18, 24)
    let titleSize = title.size()
    let clockSize = clock.size()
    let itemsWidth =
      ceil(titleSize.width) + symbols.map(\.size.width).reduce(0, +) + ceil(clockSize.width)
    let size = NSSize(
      width: itemsWidth + gap * CGFloat(symbols.count + 1) + padding * 2, height: height)
    return try framed(size: size, radius: 8, margin: Self.menuBarMargin, dark: dark) { frame in
      let wallpaper =
        dark
        ? [(0.10, 0.12, 0.30), (0.30, 0.14, 0.42), (0.55, 0.22, 0.40)]
        : [(0.62, 0.78, 0.98), (0.80, 0.74, 0.98), (0.99, 0.80, 0.84)]
      NSGradient(
        colors: wallpaper.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) })!
        .draw(in: frame, angle: 0)
      NSColor(white: dark ? 0 : 1, alpha: dark ? 0.3 : 0.45).setFill()
      frame.fill(using: .sourceOver)
      NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        var x = frame.minX + padding
        title.draw(
          at: NSPoint(x: x, y: frame.minY + ((height - titleSize.height) / 2).rounded()))
        x += ceil(titleSize.width) + gap
        for symbol in symbols {
          symbol.draw(
            in: NSRect(
              x: x, y: frame.minY + ((height - symbol.size.height) / 2).rounded(),
              width: symbol.size.width, height: symbol.size.height))
          x += symbol.size.width + gap
        }
        clock.draw(at: NSPoint(x: x, y: frame.minY + ((height - clockSize.height) / 2).rounded()))
      }
    }
  }

  /// Draws content into a rounded frame with a hairline border and drop shadow, so the image stays
  /// distinct on a page of the same color as its background.
  private func framed(
    size: NSSize, radius: CGFloat, margin: CGFloat = margin, dark: Bool, draw: (NSRect) -> Void
  ) throws -> Data {
    let canvas = try bitmap(
      size: NSSize(width: size.width + margin * 2, height: size.height + margin * 2))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: canvas))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let frame = NSRect(origin: NSPoint(x: margin, y: margin), size: size)
    let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.18)
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.shadowBlurRadius = 18
    shadow.set()
    NSColor.black.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    draw(frame)
    NSGraphicsContext.restoreGraphicsState()
    let border = NSBezierPath(
      roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), xRadius: radius - 0.25, yRadius: radius - 0.25
    )
    border.lineWidth = 0.5
    (dark ? NSColor.white.withAlphaComponent(0.2) : NSColor.black.withAlphaComponent(0.15))
      .setStroke()
    border.stroke()
    context.flushGraphics()
    return try XCTUnwrap(canvas.representation(using: .png, properties: [:]))
  }

  private func bitmap(size: NSSize) throws -> NSBitmapImageRep {
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * Self.scale,
        pixelsHigh: Int(size.height) * Self.scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0))
    bitmap.size = size
    return bitmap
  }
}
