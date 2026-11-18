import AppKit
import DeltaveeCore
import XCTest

@testable import Deltavee

// Explicit Objective-C names keep the test's own type names ("MenuPanelTests") out of `className`.
@objc(DeltaveePickerMenuWindow) private final class PickerMenuWindow: NSWindow {}
@objc(DeltaveePickerPopoverWindow) private final class PickerPopoverWindow: NSWindow {}

/// Stand-in for the status item and its display: a button in a never-ordered window at the top of
/// a fixed 1440×900 screen, so the panel's height cap and placement ignore the live menu bar and
/// the real displays. Pass `screen` to `MenuPanelController(screen:)`.
@MainActor
final class TestPanelAnchor {
  static let screen = MenuPanelScreen(
    frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))
  let window: NSWindow
  let button = NSButton(title: "Panel test", target: nil, action: nil)
  let screen: (NSButton?) -> MenuPanelScreen? = { _ in TestPanelAnchor.screen }

  init() {
    let frame = Self.screen.frame
    window = NSWindow(
      contentRect: NSRect(x: frame.minX + 200, y: frame.maxY - 24, width: 80, height: 24),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    button.frame = NSRect(x: 0, y: 1, width: 80, height: 22)
    window.contentView?.addSubview(button)
  }
}

final class MenuPanelTests: XCTestCase {
  func testPlacementAlignsLeftAndTopToStatusButtonRatherThanCentering() {
    let anchor = NSRect(x: 400, y: 878, width: 30, height: 22)
    let frame = MenuPanelPlacement.frame(
      anchor: anchor, visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 878),
      size: NSSize(width: 340, height: 240))

    XCTAssertEqual(frame, NSRect(x: 400, y: 632, width: 340, height: 240))
    XCTAssertEqual(frame.minX, anchor.minX)
    XCTAssertNotEqual(frame.midX, anchor.midX)
    XCTAssertEqual(frame.maxY, anchor.minY - 6)
  }

  func testPlacementClampsBothHorizontalScreenEdges() {
    let visible = NSRect(x: 0, y: 0, width: 1000, height: 780)
    let size = NSSize(width: 340, height: 200)
    let left = MenuPanelPlacement.frame(
      anchor: NSRect(x: -30, y: 780, width: 30, height: 20),
      visibleFrame: visible, size: size)
    let right = MenuPanelPlacement.frame(
      anchor: NSRect(x: 980, y: 780, width: 20, height: 20),
      visibleFrame: visible, size: size)

    XCTAssertEqual(left, NSRect(x: 8, y: 574, width: 340, height: 200))
    XCTAssertEqual(right, NSRect(x: 652, y: 574, width: 340, height: 200))
    XCTAssertEqual(right.maxX, visible.maxX - 8)
  }

  func testPlacementUsesNegativeOriginSecondaryScreenCoordinates() {
    let visible = NSRect(x: -1600, y: -200, width: 1600, height: 1000)
    let size = NSSize(width: 340, height: 300)
    let anchored = MenuPanelPlacement.frame(
      anchor: NSRect(x: -1200, y: 800, width: 28, height: 24),
      visibleFrame: visible, size: size)
    let left = MenuPanelPlacement.frame(
      anchor: NSRect(x: -1600, y: 800, width: 28, height: 24),
      visibleFrame: visible, size: size)
    let right = MenuPanelPlacement.frame(
      anchor: NSRect(x: -28, y: 800, width: 28, height: 24),
      visibleFrame: visible, size: size)

    XCTAssertEqual(anchored, NSRect(x: -1200, y: 494, width: 340, height: 300))
    XCTAssertEqual(left.minX, -1592)
    XCTAssertEqual(right.maxX, -8)
    XCTAssertTrue(visible.contains(anchored))
    XCTAssertTrue(visible.contains(left))
    XCTAssertTrue(visible.contains(right))
  }

  func testHeightChangesKeepTopEdgeAndHorizontalAnchor() {
    let anchor = NSRect(x: 300, y: 850, width: 28, height: 24)
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 850)
    let frames = [120, 480, 200].map { height in
      MenuPanelPlacement.frame(
        anchor: anchor, visibleFrame: visible,
        size: NSSize(width: 340, height: CGFloat(height)))
    }

    for (frame, height) in zip(frames, [120, 480, 200]) {
      XCTAssertEqual(frame.height, CGFloat(height))
      XCTAssertEqual(frame.maxY, 844)
      XCTAssertEqual(frame.minX, 300)
      XCTAssertEqual(frame.width, 340)
    }
    XCTAssertLessThan(frames[1].minY, frames[0].minY)
    XCTAssertGreaterThan(frames[2].minY, frames[1].minY)
  }

  func testPlacementClampsTopAndBottomAndFitsSmallDisplay() {
    let visible = NSRect(x: -200, y: -100, width: 220, height: 140)
    let oversized = MenuPanelPlacement.frame(
      anchor: NSRect(x: 10, y: 100, width: 30, height: 20),
      visibleFrame: visible, size: NSSize(width: 340, height: 600))
    XCTAssertEqual(oversized, NSRect(x: -192, y: -90, width: 204, height: 124))
    XCTAssertTrue(visible.contains(oversized))
    XCTAssertEqual(oversized.maxY, visible.maxY - 6)

    let bottom = MenuPanelPlacement.frame(
      anchor: NSRect(x: -150, y: -90, width: 30, height: 20),
      visibleFrame: visible, size: NSSize(width: 100, height: 60))
    XCTAssertEqual(bottom, NSRect(x: -150, y: -92, width: 100, height: 60))
    XCTAssertTrue(visible.contains(bottom))
  }

  func testStatusItemHitIncludesAllEdgesAndStripUpToScreenTop() {
    let anchor = NSRect(x: -80, y: 970, width: 30, height: 22)
    for x in [CGFloat(-80), -65, -50] {
      for y in [CGFloat(970), 981, 992, 996, 1000] {
        XCTAssertTrue(
          MenuPanelPlacement.hitsStatusItem(
            NSPoint(x: x, y: y), anchor: anchor, screenTop: 1000),
          "Status-item click at (\(x), \(y)) must not close before toggle reopens the panel")
      }
    }
    for point in [
      NSPoint(x: -80.01, y: 980), NSPoint(x: -49.99, y: 980),
      NSPoint(x: -65, y: 969.99), NSPoint(x: -65, y: 1000.01),
      NSPoint(x: -90, y: 999), NSPoint(x: 0, y: 0),
    ] {
      XCTAssertFalse(
        MenuPanelPlacement.hitsStatusItem(point, anchor: anchor, screenTop: 1000),
        "Outside click at \(point) must remain dismissible")
    }
  }

  func testStatusItemHitRetainsButtonTopWhenScreenTopIsLowerAndRejectsEmptyAnchors() {
    let anchor = NSRect(x: 50, y: 90, width: 30, height: 24)
    XCTAssertTrue(
      MenuPanelPlacement.hitsStatusItem(NSPoint(x: 80, y: 114), anchor: anchor, screenTop: 100))
    XCTAssertFalse(
      MenuPanelPlacement.hitsStatusItem(NSPoint(x: 65, y: 114.01), anchor: anchor, screenTop: 100))
    for empty in [
      NSRect.zero, NSRect(x: 50, y: 90, width: 0, height: 24),
      NSRect(x: 50, y: 90, width: 30, height: 0),
    ] {
      XCTAssertFalse(
        MenuPanelPlacement.hitsStatusItem(empty.origin, anchor: empty, screenTop: 1000))
    }
  }

  @MainActor
  func testPanelStyleAndSynchronousShowHideReopenAndShutdown() async throws {
    let fixture = Fixture()
    defer { fixture.shutdown() }
    let controller = fixture.controller
    let panel = controller.panel
    XCTAssertFalse(panel.styleMask.contains(.titled))
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertEqual(panel.animationBehavior, .none)
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertFalse(controller.isPresented)
    XCTAssertFalse(panel.isVisible)

    controller.show()
    try await settle(panel)
    XCTAssertTrue(controller.isPresented)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 1)
    XCTAssertGreaterThan(panel.frame.height, 100)
    let original = panel.frame
    controller.show()
    XCTAssertEqual(panel.frame, original)

    controller.hide()
    XCTAssertFalse(controller.isPresented)
    XCTAssertFalse(panel.isVisible, "Reduce Motion must order out synchronously")
    controller.show()
    try await settle(panel)
    XCTAssertTrue(controller.isPresented)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 1)
    XCTAssertEqual(panel.frame.height, original.height, accuracy: 1)
    controller.toggle()
    XCTAssertFalse(controller.isPresented)
    XCTAssertFalse(panel.isVisible)
    controller.toggle()
    try await settle(panel)
    XCTAssertTrue(controller.isPresented)
    XCTAssertTrue(panel.isVisible)
    controller.shutdown()
    XCTAssertFalse(controller.isPresented)
    XCTAssertFalse(panel.isVisible)
    XCTAssertNil(panel.onCancel)
  }

  @MainActor
  func testThemeOverridesPanelAppearanceOnlyAndSystemFollowsMacOS() throws {
    let fixture = Fixture()
    defer { fixture.shutdown() }
    let panel = fixture.controller.panel
    let statusAppearance = fixture.anchor.window.appearance
    XCTAssertNil(panel.appearance)
    fixture.controller.apply(theme: .dark)
    XCTAssertEqual(panel.appearance?.name, .darkAqua)
    XCTAssertEqual(
      panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    fixture.controller.apply(theme: .light)
    XCTAssertEqual(panel.appearance?.name, .aqua)
    XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    fixture.controller.apply(theme: .system)
    XCTAssertNil(panel.appearance)
    XCTAssertEqual(fixture.anchor.window.appearance, statusAppearance)
  }

  @MainActor
  func testPanelMaterialIsClippedByMaskImageInsteadOfLayerCorners() throws {
    let fixture = Fixture()
    defer { fixture.shutdown() }
    let background = try XCTUnwrap(fixture.controller.panel.contentView as? NSVisualEffectView)
    XCTAssertEqual(background.blendingMode, .behindWindow)
    // Layer masks do not clip the window-server blur; only maskImage removes the square corners.
    XCTAssertEqual(background.layer?.cornerRadius ?? 0, 0)
    XCTAssertFalse(background.layer?.masksToBounds ?? false)
    let mask = try XCTUnwrap(background.maskImage)
    let radius = PanelView.cornerRadius
    XCTAssertEqual(mask.resizingMode, .stretch)
    XCTAssertTrue(
      NSEdgeInsetsEqual(
        mask.capInsets, NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)))
  }

  @MainActor
  func testCornerMaskKeepsRadiusWhenStretchedToPanelSize() throws {
    let radius = PanelView.cornerRadius
    let size = NSSize(width: PanelView.width, height: 400)
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    MenuPanelController.cornerMask(radius: radius).draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
      bitmap.colorAt(x: Int(x), y: Int(y))?.alphaComponent ?? -1
    }
    let (maxX, maxY) = (size.width - 1, size.height - 1)
    // Every corner pixel outside the arc stays transparent, so the material never shows there.
    for (x, y) in [(1, 1), (maxX - 1, 1), (1, maxY - 1), (maxX - 1, maxY - 1)] {
      XCTAssertEqual(alpha(x, y), 0, "corner (\(x), \(y))")
    }
    // Just inside the arc stays opaque; a stretched (non cap-inset) mask would cut it away.
    let inset = radius / 2
    for (x, y) in [
      (inset, inset), (maxX - inset, inset), (inset, maxY - inset), (maxX - inset, maxY - inset),
    ] {
      XCTAssertEqual(alpha(x, y), 1, "arc (\(x), \(y))")
    }
    XCTAssertEqual(alpha(0, size.height / 2), 1)
    XCTAssertEqual(alpha(size.width / 2, 0), 1)
    XCTAssertEqual(alpha(size.width / 2, size.height / 2), 1)
  }

  @MainActor
  func testControllerContentGrowthAndShrinkRetainTopAndUseStatusItemAnchor() async throws {
    let fixture = Fixture()
    defer { fixture.shutdown() }
    let button = fixture.anchor.button
    let window = fixture.anchor.window
    let screen = TestPanelAnchor.screen
    let controller = fixture.controller
    controller.show()
    try await settle(controller.panel)
    let empty = controller.panel.frame
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    let expected = MenuPanelPlacement.frame(
      anchor: anchor, visibleFrame: screen.visibleFrame,
      size: NSSize(width: PanelView.width, height: empty.height))
    XCTAssertEqual(empty.minX, expected.minX, accuracy: 1)
    XCTAssertEqual(empty.maxY, expected.maxY, accuracy: 1)
    XCTAssertEqual(empty.width, min(PanelView.width, screen.visibleFrame.width - 16), accuracy: 1)

    fixture.model.document.accounts = [
      Account(name: "Work account", provider: .openai, configDir: "/fake/menu-panel")
    ]
    try await settle(controller.panel)
    let grown = controller.panel.frame
    XCTAssertGreaterThan(grown.height, empty.height)
    XCTAssertEqual(grown.maxY, empty.maxY, accuracy: 1)
    XCTAssertEqual(grown.minX, empty.minX, accuracy: 1)
    XCTAssertEqual(grown.width, empty.width, accuracy: 1)
    fixture.model.document.accounts.removeAll()
    try await settle(controller.panel)
    XCTAssertEqual(controller.panel.frame.height, empty.height, accuracy: 1)
    XCTAssertEqual(controller.panel.frame.maxY, empty.maxY, accuracy: 1)
    XCTAssertTrue(controller.isPresented)
  }

  @MainActor
  func testSettingsEscapeReturnsToAccountsAndPanelCancelDismissesAndResetsNavigation() async throws
  {
    let fixture = Fixture()
    defer { fixture.shutdown() }
    let controller = fixture.controller
    controller.show()
    try await settle(controller.panel)
    let accounts = controller.panel.frame
    let document = fixture.model.document
    let open = try keyEvent(in: controller.panel, characters: ",", keyCode: 43, modifiers: .command)
    let escape = try keyEvent(in: controller.panel, characters: "\u{1b}", keyCode: 53)

    XCTAssertTrue(controller.panel.performKeyEquivalent(with: open))
    try await settle(controller.panel)
    XCTAssertGreaterThan(controller.panel.frame.height, accounts.height)
    XCTAssertEqual(controller.panel.frame.maxY, accounts.maxY, accuracy: 1)
    XCTAssertTrue(controller.panel.performKeyEquivalent(with: escape))
    try await settle(controller.panel)
    XCTAssertTrue(controller.isPresented, "Settings Escape navigates back instead of dismissing")
    XCTAssertTrue(controller.panel.isVisible)
    XCTAssertEqual(controller.panel.frame.height, accounts.height, accuracy: 1)
    XCTAssertEqual(fixture.model.document, document)

    XCTAssertTrue(
      controller.panel.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))
    XCTAssertFalse(controller.isPresented, "Account-page Escape reaches the panel responder")
    XCTAssertFalse(controller.panel.isVisible)
    controller.show()
    try await settle(controller.panel)
    XCTAssertTrue(controller.panel.performKeyEquivalent(with: open))
    try await settle(controller.panel)
    XCTAssertGreaterThan(controller.panel.frame.height, accounts.height)
    controller.hide()
    controller.show()
    try await settle(controller.panel)
    XCTAssertTrue(controller.isPresented)
    XCTAssertEqual(controller.panel.frame.height, accounts.height, accuracy: 1)
    XCTAssertEqual(fixture.model.document, document, "Dismissal must not save the settings draft")
  }

  @MainActor
  func testOutsideClickDismissesButPanelAndStatusButtonClicksDoNot() {
    // Synthetic geometry: the real menu bar and live mouse monitors play no part in the decision.
    let panel = MenuPanel(
      contentRect: NSRect(x: 100, y: 700, width: 320, height: 240), styleMask: [.borderless],
      backing: .buffered, defer: true)
    let anchor = NSRect(x: 100, y: 970, width: 80, height: 22)
    func dismisses(_ point: NSPoint, in window: NSWindow? = nil, anchor: NSRect? = anchor) -> Bool {
      MenuPanelPlacement.dismisses(
        eventWindow: window, at: point, panel: panel, anchor: anchor, screenTop: 1000)
    }
    let outside = NSPoint(x: 50, y: 650)

    XCTAssertFalse(
      dismisses(NSPoint(x: 140, y: 1000)),
      "The status-button mouse-down must leave toggling to mouse-up")
    XCTAssertFalse(dismisses(NSPoint(x: 140, y: 980)))
    XCTAssertFalse(dismisses(NSPoint(x: 260, y: 820)), "Clicks inside the panel keep it open")
    XCTAssertFalse(
      dismisses(outside, in: panel), "Panel-targeted events stay inside the current UI")
    let child = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
      backing: .buffered, defer: true)
    panel.addChildWindow(child, ordered: .above)
    defer { panel.removeChildWindow(child) }
    XCTAssertFalse(dismisses(outside, in: child), "Child windows of the panel are inside the UI")
    for window in [
      PickerMenuWindow(
        contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true),
      PickerPopoverWindow(
        contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true),
    ] as [NSWindow] {
      XCTAssertFalse(dismisses(outside, in: window), "\(window.className) is a native picker")
    }

    XCTAssertTrue(dismisses(outside))
    XCTAssertTrue(dismisses(NSPoint(x: 181, y: 1000)), "Beside the status button is outside")
    XCTAssertTrue(
      dismisses(
        outside,
        in: NSWindow(
          contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)))
    XCTAssertTrue(
      dismisses(NSPoint(x: 140, y: 1000), anchor: nil),
      "Without a status item window the strip is an outside click")
  }

  @MainActor
  func testOtherAppActivationDismissesOnlyWhenSystemEventsAreMonitored() throws {
    let other = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
      })
    let fixture = Fixture()
    defer { fixture.shutdown() }
    let monitored = MenuPanelController(
      model: fixture.model, button: { [anchor = fixture.anchor] in anchor.button },
      reduceMotion: { true }, screen: fixture.anchor.screen)
    defer { monitored.shutdown() }
    // No run-loop turn between show and the posted notification, so real app switches cannot interfere.
    fixture.controller.show()
    monitored.show()
    XCTAssertTrue(fixture.controller.isPresented)
    XCTAssertTrue(monitored.isPresented)

    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
      userInfo: [NSWorkspace.applicationUserInfoKey: other])
    XCTAssertFalse(monitored.isPresented, "The app dismisses the panel when another app activates")
    XCTAssertTrue(
      fixture.controller.isPresented, "Test fixtures ignore the user's app switches")
  }

  @MainActor
  func testHeightCapAndPlacementFollowInjectedScreen() async throws {
    let fixture = Fixture()
    defer { fixture.shutdown() }
    // Cap: the visible height minus the 40pt screen margin, not the real display's height.
    let cap: CGFloat = 160
    let short = MenuPanelScreen(
      frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: NSRect(x: 0, y: 675, width: 1440, height: cap + 40))
    fixture.model.document.accounts = (0..<8).map {
      Account(name: "Account \($0)", provider: .openai, configDir: "/fake/cap-\($0)")
    }

    // Premise: uncapped, the panel is clearly taller than the cap, so the cap must clip it.
    let tall = MenuPanelScreen(
      frame: NSRect(x: 0, y: 0, width: 1440, height: 5100),
      visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 5075))
    let uncapped = MenuPanelController(
      model: fixture.model, button: { [anchor = fixture.anchor] in anchor.button },
      reduceMotion: { true }, monitorsSystemEvents: false, screen: { _ in tall })
    uncapped.show()
    try await settle(uncapped.panel)
    let natural = uncapped.panel.frame.height
    uncapped.shutdown()
    XCTAssertGreaterThan(natural, cap * 2, "The fixture must stay far taller than the cap")

    let controller = MenuPanelController(
      model: fixture.model, button: { [anchor = fixture.anchor] in anchor.button },
      reduceMotion: { true }, monitorsSystemEvents: false, screen: { _ in short })
    defer { controller.shutdown() }
    controller.show()
    try await settle(controller.panel)

    let frame = controller.panel.frame
    XCTAssertEqual(frame.height, cap, accuracy: 1)
    XCTAssertEqual(frame.minX, 200, accuracy: 1)
    // The anchor (y 877) sits in the menu bar strip above the visible top (875).
    XCTAssertEqual(frame.maxY, 875 - MenuPanelPlacement.gap, accuracy: 1)
    XCTAssertGreaterThanOrEqual(frame.minY, short.visibleFrame.minY + MenuPanelPlacement.inset)
  }

  @MainActor
  func testControllerOutsideClickHidesPresentedPanel() async throws {
    let fixture = Fixture()
    defer { fixture.shutdown() }
    let controller = fixture.controller
    controller.show()
    try await settle(controller.panel)
    XCTAssertTrue(controller.isPresented)
    // Off every screen: no status item or panel can contain this point.
    controller.handleClick(eventWindow: nil, at: NSPoint(x: -100_000, y: -100_000))
    XCTAssertFalse(controller.isPresented)
    XCTAssertFalse(controller.panel.isVisible)
  }

  @MainActor
  private func keyEvent(
    in window: NSWindow, characters: String, keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = []
  ) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
  }

  @MainActor
  private func settle(_ window: NSWindow) async throws {
    // Match PanelSizingTests: allow geometry preferences and both layout passes to complete.
    for _ in 0..<10 {
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @MainActor
  private final class Fixture {
    let directory: URL
    let model: AppModel
    let anchor = TestPanelAnchor()
    let controller: MenuPanelController

    init() {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      model = AppModel(
        accountStore: AccountStore(directory: directory),
        snapshotStore: SnapshotStore(directory: directory))
      let button = anchor.button
      controller = MenuPanelController(
        model: model, button: { button }, reduceMotion: { true }, monitorsSystemEvents: false,
        screen: anchor.screen)
    }

    func shutdown() {
      controller.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
