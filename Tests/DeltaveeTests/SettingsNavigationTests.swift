import AppKit
import DeltaveeCore
import SwiftUI
import XCTest

@testable import Deltavee

private actor SettingsNavigationCollector: Collector {
  func fetch(_ account: Account) async -> Result<CollectedUsage, CollectError> {
    .failure(CollectError(.authRequired))
  }
}

final class SettingsNavigationTests: XCTestCase {
  @MainActor
  func testAccountsAndSettingsAreSeparateCappedScreensThatRestoreCollapsedHeight() async throws {
    try await withHost(maxHeight: 600) { fixture in
      let window = fixture.window
      try await self.settle(window)
      let panel = window.contentLayoutRect.height
      let windowCount = NSApp.windows.filter(\.isVisible).count
      try self.openAccounts(in: window)
      try await self.settle(window)
      let collapsed = window.contentLayoutRect.height
      XCTAssertLessThan(collapsed, 600)
      XCTAssertTrue(
        self.editableFields(in: window.contentView!).isEmpty,
        "Collapsed cards must not expose their detail editors")

      try self.press("e", keyCode: 14, modifiers: [.command, .option], in: window)
      try await self.settle(window)
      XCTAssertGreaterThan(window.contentLayoutRect.height, collapsed)
      XCTAssertLessThanOrEqual(window.contentLayoutRect.height, 600)
      let accountFields = self.editableFields(in: window.contentView!).map(\.stringValue)
      XCTAssertTrue(accountFields.contains("/fake/account-0"))
      XCTAssertFalse(
        accountFields.contains("/fake/original-codex"), "Accounts must not show app settings")
      try self.press("e", keyCode: 14, modifiers: [.command, .option], in: window)
      try await self.settle(window)
      XCTAssertEqual(window.contentLayoutRect.height, collapsed, accuracy: 1)
      try self.press("\u{1b}", keyCode: 53, in: window)
      try await self.settle(window)
      XCTAssertEqual(window.contentLayoutRect.height, panel, accuracy: 1)

      try self.press(",", keyCode: 43, modifiers: .command, in: window)
      try await self.settle(window)
      let settingsFields = self.editableFields(in: window.contentView!).map(\.stringValue)
      XCTAssertEqual(
        settingsFields, ["", "/fake/original-codex"],
        "One scrolling Settings screen holds display and collection editors, but no accounts")
      XCTAssertLessThanOrEqual(window.contentLayoutRect.height, 600)
      XCTAssertEqual(window.contentLayoutRect.width, PanelView.width, accuracy: 1)
      try self.press("\u{1b}", keyCode: 53, in: window)
      try await self.settle(window)
      XCTAssertEqual(window.contentLayoutRect.height, panel, accuracy: 1)
      XCTAssertEqual(
        NSApp.windows.filter(\.isVisible).count, windowCount,
        "Windows: \(NSApp.windows.map { ($0.className, $0.isVisible) })")
      XCTAssertEqual(fixture.model.document, fixture.original)
    }
  }

  @MainActor
  func testSettingsScrollsAsOneScreenWhenTallerThanCap() async throws {
    try await withHost(maxHeight: 400) { fixture in
      let window = fixture.window
      try await self.settle(window)
      try self.press(",", keyCode: 43, modifiers: .command, in: window)
      try await self.settle(window)
      XCTAssertEqual(window.contentLayoutRect.height, 400, accuracy: 1)
      let scroll = try XCTUnwrap(self.scrollView(in: window.contentView!))
      XCTAssertGreaterThan(
        try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height)
      // Collection editors sit below the fold but belong to the same scroller.
      XCTAssertNotNil(
        self.editableFields(in: scroll).first { $0.stringValue == "/fake/original-codex" })
    }
  }

  /// Wrapping any row label, the color legend or the OAuth warning makes the screen taller
  /// than at a width where every line fits, so equal heights prove they stay on one line.
  /// The statusline-only source swaps the warning for a help sentence that may wrap, so the
  /// check uses the OAuth source, where every visible text is meant to be a single line.
  @MainActor
  func testSettingsLabelsStayOnOneLineAtPanelWidth() async throws {
    try await withHost(maxHeight: 600) { fixture in
      fixture.model.document.settings.claudeSource = .oauthWithStatusline
      for mode in [PercentMode.used, .remaining] {
        for format in TimeFormat.allCases {
          fixture.model.document.settings.mode = mode
          fixture.model.document.settings.timeFormat = format
          let panel = try await self.settingsHeight(model: fixture.model, width: PanelView.width)
          let unconstrained = try await self.settingsHeight(model: fixture.model, width: 800)
          XCTAssertGreaterThan(unconstrained, 0)
          XCTAssertEqual(
            panel, unconstrained, accuracy: 1,
            "Settings text wraps at \(PanelView.width)pt for \(mode)/\(format)")
        }
      }
    }
  }

  @MainActor
  func testCompactTimeAndSourceMenusApplyImmediatelyAndAlignWithInterval() async throws {
    try await withHost(maxHeight: 1000) { fixture in
      let window = fixture.window
      try await self.settle(window)
      try self.press(",", keyCode: 43, modifiers: .command, in: window)
      try await self.settle(window)
      let host = try XCTUnwrap(window.contentView)
      let menus = self.popUpButtons(in: host)
      XCTAssertEqual(menus.count, 7)
      let clock = try XCTUnwrap(menus.first { $0.itemTitles.contains("12-Hour") })
      let source = try XCTUnwrap(menus.first { $0.itemTitles.contains("Statusline Only") })
      let interval = try XCTUnwrap(menus.first { $0.itemTitles.contains("10 min") })
      let updated = try XCTUnwrap(menus.first { $0.itemTitles.contains("Time Ago") })
      XCTAssertEqual(updated.itemTitles, ["Date & Time", "Time Ago"])
      XCTAssertEqual(updated.accessibilityLabel(), "Updated time")
      XCTAssertEqual(clock.itemTitles, ["System", "12-Hour", "24-Hour"])
      XCTAssertEqual(clock.titleOfSelectedItem, "System")
      // Tool tips are read from the AppKit control, so no pointer hover is needed.
      XCTAssertEqual(
        clock.toolTip,
        "Applies to tooltips and Date & Time displays. System follows the Mac's 12-hour or 24-hour clock setting"
      )
      XCTAssertEqual(
        source.toolTip, "Unofficial OAuth + statusline fallback, or local statusline only")
      XCTAssertNil(updated.toolTip)
      XCTAssertEqual(source.itemTitles, ["OAuth + Statusline", "Statusline Only"])
      // The default comes first among the two percent modes.
      let usage = try XCTUnwrap(menus.first { $0.itemTitles.contains("Remaining") })
      XCTAssertEqual(usage.itemTitles, ["Remaining", "Used"])
      XCTAssertEqual(usage.accessibilityLabel(), "Show usage as")
      let edge = interval.convert(interval.bounds, to: host).maxX
      for menu in menus where menu !== source {
        XCTAssertEqual(menu.bounds.width, 124, accuracy: 1)
      }
      XCTAssertEqual(source.bounds.width, 164, accuracy: 1)
      XCTAssertLessThan(
        interval.convert(interval.bounds, to: host).minY,
        source.convert(source.bounds, to: host).minY)
      for menu in menus {
        let rect = menu.convert(menu.bounds, to: host)
        XCTAssertEqual(rect.maxX, edge, accuracy: 1)
        XCTAssertLessThanOrEqual(
          menu.intrinsicContentSize.width, rect.width,
          "Selected title must fit: \(menu.titleOfSelectedItem ?? "")")
        XCTAssertLessThanOrEqual(rect.maxX, host.bounds.maxX)
      }
      // Switches that share a card with pop-up menus end at the same trailing edge.
      let switches = self.switches(in: host)
      XCTAssertEqual(switches.count, 3)
      for control in switches {
        XCTAssertEqual(control.convert(control.bounds, to: host).maxX, edge, accuracy: 1)
      }
      var expected = fixture.original
      for (title, format) in [
        ("24-Hour", TimeFormat.hour24), ("12-Hour", .hour12), ("System", .auto),
      ] {
        clock.menu?.performActionForItem(at: clock.indexOfItem(withTitle: title))
        try await self.settle(window)
        expected.settings.timeFormat = format
        XCTAssertEqual(fixture.model.document, expected)
        XCTAssertEqual(try fixture.store.load(), expected)
      }
      for (title, mode) in [("Time Ago", TimeDisplayMode.relative), ("Date & Time", .absolute)] {
        updated.menu?.performActionForItem(at: updated.indexOfItem(withTitle: title))
        try await self.settle(window)
        expected.settings.updatedTimeMode = mode
        XCTAssertEqual(fixture.model.document, expected)
        XCTAssertEqual(try fixture.store.load(), expected)
      }
      source.menu?.performActionForItem(at: source.indexOfItem(withTitle: "Statusline Only"))
      try await self.settle(window)
      expected.settings.claudeSource = .statuslineOnly
      XCTAssertEqual(try fixture.store.load(), expected)
      let path = try XCTUnwrap(self.editableFields(in: host).first)
      XCTAssertEqual(path.placeholderString, "Auto-detect")
    }
  }

  @MainActor
  func testTermsHeadersToggleFromLabelAndTrailingWhitespace() async throws {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 280, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    let host = NSHostingView(
      rootView: SettingsTermsDetails {
        TextField("Policy details", text: .constant("Policy details")).frame(height: 40)
      }
      .padding(8)
      .frame(width: 280, height: 200, alignment: .topLeading))
    window.contentView = host
    window.orderFrontRegardless()
    try await settle(window)
    XCTAssertTrue(editableFields(in: host).isEmpty)
    for x: CGFloat in [40, 268, 13] {
      let point = NSPoint(x: x, y: 185)
      try mouse(.leftMouseDown, at: point, in: window)
      try mouse(.leftMouseUp, at: point, in: window)
      try await settle(window)
      XCTAssertEqual(
        editableFields(in: host).map(\.stringValue), ["Policy details"],
        "Clicking the header at x=\(x) must reveal policy details")
      try mouse(.leftMouseDown, at: point, in: window)
      try mouse(.leftMouseUp, at: point, in: window)
      try await settle(window)
      XCTAssertTrue(
        editableFields(in: host).isEmpty, "Clicking again must collapse policy details")
    }
  }

  @MainActor
  private func settingsHeight(model: AppModel, width: CGFloat) async throws -> CGFloat {
    var height: CGFloat = 0
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 1),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer {
      window.contentView = nil
      window.close()
    }
    window.contentView = NSHostingView(
      rootView: SettingsView(
        model: model, page: .settings, width: width, maxHeight: 5000, onClose: {},
        onHeightChange: { height = $0 }))
    try await settle(window)
    return height
  }

  @MainActor
  func testTextEditsApplyOnFocusLossReturnAndLeavingButNotWhileTyping() async throws {
    try await withHost(maxHeight: 800) { fixture in
      let window = fixture.window
      try await self.settle(window)
      let windowCount = NSApp.windows.filter(\.isVisible).count
      try self.press(",", keyCode: 43, modifiers: .command, in: window)
      try await self.settle(window)
      var expected = fixture.original

      let typing = try self.typeCodexPath(
        "/fake/focus-codex", replacing: "/fake/original-codex", in: window)
      try await self.settle(window)
      XCTAssertEqual(fixture.model.document, fixture.original, "Typing alone must not apply")
      XCTAssertTrue(window.makeFirstResponder(nil))
      try await self.settle(window)
      XCTAssertEqual(typing.stringValue, "/fake/focus-codex")
      expected.settings.codexPath = "/fake/focus-codex"
      XCTAssertEqual(fixture.model.document, expected, "Focus loss applies the edit")
      XCTAssertEqual(try fixture.store.load(), expected)

      let editor = try XCTUnwrap(
        try self.typeCodexPath("/fake/return-codex", replacing: "/fake/focus-codex", in: window)
          .currentEditor() as? NSTextView)
      XCTAssertEqual(fixture.model.document, expected)
      editor.insertNewline(nil)
      try await self.settle(window)
      expected.settings.codexPath = "/fake/return-codex"
      XCTAssertEqual(fixture.model.document, expected, "Return applies the edit")

      let claude = try XCTUnwrap(
        self.editableFields(in: window.contentView!).first { $0.stringValue.isEmpty })
      XCTAssertEqual(claude.placeholderString, "Auto-detect")
      let claudePath = "/fake/mise installations/claude"
      try self.type(claudePath, into: claude, in: window)
      XCTAssertEqual(try fixture.store.load(), expected, "Typing alone must not apply")
      XCTAssertTrue(window.makeFirstResponder(nil))
      try await self.settle(window)
      expected.settings.claudePath = claudePath
      XCTAssertEqual(
        try fixture.store.load(), expected, "Claude and Codex paths save independently")

      _ = try self.typeCodexPath("/fake/escape-codex", replacing: "/fake/return-codex", in: window)
      try self.press("\u{1b}", keyCode: 53, in: window)
      try await self.settle(window)
      XCTAssertTrue(
        self.editableFields(in: window.contentView!).isEmpty, "Escape returns to the usage panel")
      expected.settings.codexPath = "/fake/escape-codex"
      XCTAssertEqual(fixture.model.document, expected, "Leaving settings keeps the pending edit")
      XCTAssertEqual(try fixture.store.load(), expected)
      XCTAssertEqual(window.contentLayoutRect.width, PanelView.width, accuracy: 1)
      XCTAssertEqual(
        NSApp.windows.filter(\.isVisible).count, windowCount,
        "Windows: \(NSApp.windows.map { ($0.className, $0.isVisible) })")
    }
  }

  @MainActor
  func testIntervalPickerOffersFixedChoicesAndAppliesSelection() async throws {
    try await withHost(maxHeight: 800) { fixture in
      let window = fixture.window
      try await self.settle(window)
      try self.press(",", keyCode: 43, modifiers: .command, in: window)
      try await self.settle(window)
      let menu = try XCTUnwrap(
        self.popUpButtons(in: window.contentView!).first { $0.itemTitles.contains("3 min") })
      XCTAssertEqual(menu.itemTitles, ["3 min", "5 min", "10 min", "15 min", "30 min"])
      XCTAssertEqual(menu.titleOfSelectedItem, "10 min")
      var expected = fixture.original
      for (title, applied) in [("3 min", 180.0), ("30 min", 1800)] {
        // SwiftUI observes the menu item's action, as a real mouse selection would trigger it.
        let index = menu.indexOfItem(withTitle: title)
        XCTAssertNotEqual(index, -1)
        menu.menu?.performActionForItem(at: index)
        try await self.settle(window)
        expected.settings.intervalSeconds = applied
        XCTAssertEqual(fixture.model.document, expected, "Choice: \(title)")
        XCTAssertEqual(menu.titleOfSelectedItem, title)
      }
      XCTAssertEqual(try fixture.store.load(), expected)
    }
  }

  @MainActor
  func testManyExpandedCardsScrollWithinCapWithoutLosingSettingsChrome() async throws {
    try await withHost(accountCount: 8, maxHeight: 480) { fixture in
      let window = fixture.window
      try await self.settle(window)
      try self.openAccounts(in: window)
      try await self.settle(window)
      try self.press("e", keyCode: 14, modifiers: [.command, .option], in: window)
      try await self.settle(window)
      XCTAssertEqual(window.contentLayoutRect.width, PanelView.width, accuracy: 1)
      XCTAssertEqual(window.contentLayoutRect.height, 480, accuracy: 1)
      let scroll = try XCTUnwrap(self.scrollView(in: window.contentView!))
      XCTAssertGreaterThan(
        try XCTUnwrap(scroll.documentView).bounds.height,
        scroll.contentView.bounds.height)
      XCTAssertLessThan(
        scroll.bounds.height, window.contentLayoutRect.height - 40,
        "The title bar must remain outside the account scroller")
      try self.press("\u{1b}", keyCode: 53, in: window)
      try await self.settle(window)
      XCTAssertEqual(fixture.model.document, fixture.original)
      XCTAssertEqual(try fixture.store.load(), fixture.original)
    }
  }

  @MainActor
  func testControllerKeyboardNavigationKeepsSamePanelAndTopAnchor() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    _ = NSApplication.shared
    let model = AppModel(
      accountStore: AccountStore(directory: directory),
      snapshotStore: SnapshotStore(directory: directory))
    let anchor = TestPanelAnchor()
    let controller = MenuPanelController(
      model: model, button: { anchor.button }, reduceMotion: { true },
      monitorsSystemEvents: false, screen: anchor.screen)
    defer {
      controller.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    controller.show()
    try await settle(controller.panel)
    let panel = controller.panel
    let original = panel.frame
    let windowCount = NSApp.windows.count
    for (characters, code, modifiers) in [
      (",", UInt16(43), NSEvent.ModifierFlags.command), ("a", 0, [.command, .shift]),
    ] {
      try press(characters, keyCode: code, modifiers: modifiers, in: panel)
      try await settle(panel)
      XCTAssertTrue(controller.panel === panel)
      XCTAssertTrue(controller.isPresented)
      XCTAssertTrue(panel.isVisible)
      XCTAssertEqual(panel.frame.width, original.width, accuracy: 1)
      XCTAssertEqual(panel.frame.maxY, original.maxY, accuracy: 1)
      XCTAssertEqual(
        NSApp.windows.count, windowCount,
        "Windows: \(NSApp.windows.map { ($0.className, $0.title, $0.isVisible) })")
      try press("\u{1b}", keyCode: 53, in: panel)
      try await settle(panel)
      XCTAssertTrue(controller.isPresented)
      XCTAssertEqual(panel.frame.height, original.height, accuracy: 1)
    }
    XCTAssertEqual(model.document, AccountDocument())
  }

  @MainActor
  func testEmptyPanelAddAccountMenuAddsChosenProviderAndOpensItsCard() async throws {
    try await withHost(accountCount: 0, maxHeight: 600) { fixture in
      let window = fixture.window
      try await self.settle(window)
      // SwiftUI builds the menu's items only while it tracks, so the choice is driven below
      // through the same Accounts screen entry point the menu items call.
      XCTAssertEqual(
        self.popUpButtons(in: try XCTUnwrap(window.contentView)).count, 1,
        "The empty panel offers one Add Account menu")
      window.contentView = NSHostingView(
        rootView: SettingsView(
          model: fixture.model, page: .accounts, adding: .openai, width: PanelView.width,
          maxHeight: 600, onClose: {}, onHeightChange: { _ in }))
      try await self.settle(window)
      XCTAssertEqual(fixture.model.document.accounts.map(\.provider), [.openai])
      XCTAssertEqual(fixture.model.document.accounts.first?.configDir, "~/.codex")
      XCTAssertEqual(try fixture.store.load(), fixture.model.document)
      XCTAssertEqual(
        self.editableFields(in: try XCTUnwrap(window.contentView)).map(\.stringValue),
        ["", "~/.codex"], "The added account's card opens with its label and directory fields")
    }
  }

  @MainActor
  private func openAccounts(in window: NSWindow) throws {
    try press("a", keyCode: 0, modifiers: [.command, .shift], in: window)
  }

  /// Replaces a field's text through its field editor and leaves the field focused.
  @MainActor
  private func typeCodexPath(_ value: String, replacing current: String, in window: NSWindow)
    throws -> NSTextField
  {
    let field = try XCTUnwrap(
      editableFields(in: window.contentView!).first { $0.stringValue == current })
    try type(value, into: field, in: window)
    return field
  }

  @MainActor
  private func switches(in view: NSView) -> [NSSwitch] {
    if let control = view as? NSSwitch { return [control] }
    return view.subviews.flatMap { switches(in: $0) }
  }

  @MainActor
  private func popUpButtons(in view: NSView) -> [NSPopUpButton] {
    if let button = view as? NSPopUpButton { return [button] }
    return view.subviews.flatMap { popUpButtons(in: $0) }
  }

  @MainActor
  private func type(_ value: String, into field: NSTextField, in window: NSWindow) throws {
    XCTAssertTrue(window.makeFirstResponder(field))
    field.selectText(nil)
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.insertText(
      value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    XCTAssertEqual(field.stringValue, value)
  }

  @MainActor
  func testDraggingCardHandleLiftsCardShiftsOthersAndSavesNewOrder() async throws {
    try await withHost(accountCount: 3, maxHeight: 800) { fixture in
      let window = fixture.window
      try await self.settle(window)
      try self.openAccounts(in: window)
      try await self.settle(window)
      let host = try XCTUnwrap(window.contentView)
      let before = try self.snapshot(host)
      // The test window has no background, so card fills are the only painted rows at this column.
      let cards = try XCTUnwrap(self.cardRows(in: before, column: 250), "Cards not found")
      let handles = cards.map { NSRect(x: 25, y: $0.lowerBound, width: 24, height: $0.count) }
      XCTAssertLessThan(handles[1].midY, handles[0].midY, "Cards stack downward")
      let start = NSPoint(x: handles[0].midX, y: handles[0].midY)
      // SwiftUI hit-tests mouse events only for an on-screen window.
      window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
      window.orderFrontRegardless()
      try await self.settle(window)
      try self.mouse(.leftMouseDown, at: start, in: window)
      // Drag the first card past the second card's center (window y grows upward).
      let distance = (handles[0].midY - handles[1].midY) * 1.4
      for step in 1...8 {
        try self.mouse(
          .leftMouseDragged, at: NSPoint(x: start.x, y: start.y - distance * CGFloat(step) / 8),
          in: window)
      }
      try await self.settle(window)
      let lifted = try self.snapshot(host)
      XCTAssertNotEqual(
        lifted.representation(using: .png, properties: [:]),
        before.representation(using: .png, properties: [:]),
        "Dragging must move cards before the drop")
      XCTAssertEqual(
        fixture.model.document, fixture.original, "Reordering stays in the draft while dragging")
      try self.mouse(
        .leftMouseUp, at: NSPoint(x: start.x, y: start.y - distance), in: window)
      try await self.settle(window)
      // Keep the shared NSApp window list as other tests found it.
      window.orderOut(nil)
      let ids = fixture.original.accounts.map(\.id)
      XCTAssertEqual(fixture.model.document.accounts.map(\.id), [ids[1], ids[0], ids[2]])
      XCTAssertEqual(fixture.model.document.accounts.map(\.order), [0, 1, 2])
      XCTAssertEqual(try fixture.store.load().accounts.map(\.id), [ids[1], ids[0], ids[2]])
    }
  }

  /// Window-coordinate (bottom-up) row ranges of three consecutive equal-height painted bands,
  /// which are the collapsed account cards.
  @MainActor
  private func cardRows(in bitmap: NSBitmapImageRep, column: CGFloat) -> [Range<Int>]? {
    let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
    let x = Int(column * scale)
    var bands: [Range<Int>] = []
    var start: Int?
    for y in 0...bitmap.pixelsHigh {
      let painted =
        y < bitmap.pixelsHigh && (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01
      if painted, start == nil { start = y }
      if !painted, let first = start {
        bands.append(first..<y)
        start = nil
      }
    }
    let height = Int(bitmap.size.height)
    let points = bands.map { band in
      // Flip from top-down pixels to the window's bottom-up points.
      (height - Int(CGFloat(band.upperBound) / scale))..<(height
        - Int(CGFloat(band.lowerBound) / scale))
    }
    guard points.count >= 3 else { return nil }
    for index in 0...(points.count - 3) {
      let window = Array(points[index..<index + 3])
      if window.allSatisfy({ abs($0.count - window[0].count) <= 1 && $0.count > 30 }) {
        return window
      }
    }
    return nil
  }

  @MainActor
  private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws {
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1))
    window.sendEvent(event)
  }

  @MainActor
  private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
  }

  @MainActor
  private func editableFields(in view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField, field.isEditable { return [field] }
    return view.subviews.flatMap { editableFields(in: $0) }
  }

  @MainActor
  private func scrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
  }

  @MainActor
  private func press(
    _ characters: String, keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
  ) throws {
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
        keyCode: keyCode))
    XCTAssertTrue(window.performKeyEquivalent(with: event), "Unhandled shortcut: \(characters)")
  }

  @MainActor
  private func settle(_ window: NSWindow) async throws {
    for _ in 0..<10 {
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @MainActor
  private func withHost(
    accountCount: Int = 1, maxHeight: CGFloat,
    body: (HostFixture) async throws -> Void
  ) async throws {
    let fixture = try HostFixture(accountCount: accountCount, maxHeight: maxHeight)
    do {
      try await body(fixture)
      await fixture.shutdown()
    } catch {
      await fixture.shutdown()
      throw error
    }
  }

  @MainActor
  private final class HostFixture {
    let directory: URL
    let store: AccountStore
    let original: AccountDocument
    let scheduler: Scheduler
    let model: AppModel
    let window: NSWindow

    init(accountCount: Int, maxHeight: CGFloat) throws {
      _ = NSApplication.shared
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      self.directory = directory
      let store = AccountStore(directory: directory)
      self.store = store
      var settings = Settings()
      settings.codexPath = "/fake/original-codex"
      let original = AccountDocument(
        accounts: (0..<accountCount).map {
          Account(
            name: "Account \($0)", provider: .openai, configDir: "/fake/account-\($0)",
            showInIcon: $0.isMultiple(of: 2), order: $0, identityFingerprint: "identity-\($0)")
        }, settings: settings)
      self.original = original
      do { try store.save(original) } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
      let collector = SettingsNavigationCollector()
      let scheduler = Scheduler(codex: collector, claude: collector)
      self.scheduler = scheduler
      let model = AppModel(
        accountStore: store, snapshotStore: SnapshotStore(directory: directory),
        makeScheduler: { _ in scheduler })
      self.model = model
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 1),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      self.window = window
      window.contentView = NSHostingView(
        rootView: PanelView(
          model: model, maxHeight: maxHeight,
          onHeightChange: { [weak window] height in
            window?.setContentSize(NSSize(width: PanelView.width, height: height))
          }))
    }

    func shutdown() async {
      await scheduler.stop()
      window.contentView = nil
      window.close()
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
