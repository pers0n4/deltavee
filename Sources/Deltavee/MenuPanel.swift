import AppKit
import DeltaveeCore
import QuartzCore
import SwiftUI

// OpenUsage's nonactivating, key-capable panel avoids asynchronous accessory-app activation.
@MainActor
final class MenuPanel: NSPanel {
  var onCancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The geometry of the screen the panel is placed on.
struct MenuPanelScreen: Equatable {
  var frame: NSRect
  var visibleFrame: NSRect
}

enum MenuPanelPlacement {
  static let inset: CGFloat = 8
  static let gap: CGFloat = 6

  static func frame(anchor: NSRect, visibleFrame: NSRect, size: NSSize) -> NSRect {
    let width = min(size.width, max(1, visibleFrame.width - inset * 2))
    let height = min(size.height, max(1, visibleFrame.height - inset * 2))
    let x = min(max(anchor.minX, visibleFrame.minX + inset), visibleFrame.maxX - inset - width)
    let top = min(anchor.minY - gap, visibleFrame.maxY - gap)
    let y = max(visibleFrame.minY + inset, top - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  static func hitsStatusItem(_ point: NSPoint, anchor: NSRect, screenTop: CGFloat) -> Bool {
    // macOS routes the strip above the status button to the same item, including screen edges.
    !anchor.isEmpty && point.x >= anchor.minX && point.x <= anchor.maxX
      && point.y >= anchor.minY && point.y <= max(anchor.maxY, screenTop)
  }

  /// Whether a mouse-down should dismiss the panel; `anchor` and `screenTop` describe the status item.
  @MainActor
  static func dismisses(
    eventWindow: NSWindow?, at point: NSPoint, panel: NSWindow, anchor: NSRect?,
    screenTop: CGFloat?
  ) -> Bool {
    if eventWindow === panel || eventWindow?.parent === panel { return false }
    // As in OpenUsage, native picker menus/popovers are separate AppKit windows, not outside clicks.
    if let name = eventWindow?.className.lowercased(),
      name.contains("menu") || name.contains("popover")
    {
      return false
    }
    // The status button's mouse-down leaves toggling to its mouse-up action.
    if let anchor, let screenTop, hitsStatusItem(point, anchor: anchor, screenTop: screenTop) {
      return false
    }
    return !panel.frame.contains(point)
  }
}

@MainActor
private final class MenuPanelHostingView: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class MenuPanelController {
  let panel: MenuPanel
  private(set) var isPresented = false
  private let model: AppModel
  private let button: () -> NSButton?
  private let reduceMotion: () -> Bool
  private let monitorsSystemEvents: Bool
  private let screen: (NSButton?) -> MenuPanelScreen?
  private var host: MenuPanelHostingView!
  private var maxHeight: CGFloat = 1
  private var contentHeight: CGFloat = 1
  private var contentID = UUID()
  private var transitionID = UUID()
  private var hasMeasuredContent = false
  private var awaitingPresentation = false
  private var monitors: [Any] = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private var anchorObservers: [NSObjectProtocol] = []

  init(
    model: AppModel, button: @escaping () -> NSButton?,
    reduceMotion: @escaping () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    },
    // Tests disable the desktop-wide mouse monitors and app/Space switch observers, which react to
    // whatever the user does while the suite runs.
    monitorsSystemEvents: Bool = true,
    // Tests pass a fixed screen so the height cap and placement do not follow the real display.
    screen: @escaping (NSButton?) -> MenuPanelScreen? = {
      MenuPanelController.systemScreen(for: $0)
    }
  ) {
    self.model = model
    self.button = button
    self.reduceMotion = reduceMotion
    self.monitorsSystemEvents = monitorsSystemEvents
    self.screen = screen
    panel = MenuPanel(
      contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 1),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false
    panel.isMovable = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.setAccessibilityLabel("Deltavee")

    let background = NSVisualEffectView(frame: panel.contentView!.bounds)
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    // Behind-window blur is composited by the window server, so layer masks leave square corners;
    // maskImage clips the material itself.
    background.maskImage = Self.cornerMask(radius: PanelView.cornerRadius)
    panel.contentView = background
    host = MenuPanelHostingView(rootView: AnyView(EmptyView()))
    // A nested host keeps SwiftUI intrinsic-size updates from resizing the window independently.
    host.sizingOptions = []
    host.frame = background.bounds
    host.autoresizingMask = [.width, .height]
    background.addSubview(host)
    panel.onCancel = { [weak self] in self?.hide() }
    refreshGeometry()
    rebuildContent()
  }

  /// Applies the theme to the panel window only, so the status item keeps the menu bar's appearance.
  func apply(theme: AppTheme) {
    let appearance = Self.appearance(for: theme)
    if panel.appearance?.name != appearance?.name { panel.appearance = appearance }
  }

  static func cornerMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }

  static func appearance(for theme: AppTheme) -> NSAppearance? {
    switch theme {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  func toggle() {
    if isPresented { hide() } else { show() }
  }

  func show() {
    guard button()?.window != nil else { return }
    if isPresented {
      panel.makeKeyAndOrderFront(nil)
      return
    }
    transitionID = UUID()
    refreshGeometry()
    host.layoutSubtreeIfNeeded()
    position()
    isPresented = true
    awaitingPresentation = true
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    // Key appearance is explicit; no asynchronous NSApp.activate call is required.
    panel.makeFirstResponder(nil)
    button()?.highlight(true)
    startMonitoring()
    if hasMeasuredContent { finishPresentation() }
  }

  func hide() {
    guard isPresented else { return }
    isPresented = false
    model.updates.dismissManualFeedback()
    awaitingPresentation = false
    transitionID = UUID()
    let closing = transitionID
    stopMonitoring()
    button()?.highlight(false)
    animateOpacity(to: 0, duration: 0.08) { [weak self] in
      guard let self, self.transitionID == closing, !self.isPresented else { return }
      self.panel.orderOut(nil)
      self.panel.alphaValue = 1
      // Dismissal discards the settings draft; reopening always starts at accounts.
      self.contentID = UUID()
      self.hasMeasuredContent = false
      self.rebuildContent()
    }
  }

  func shutdown() {
    transitionID = UUID()
    isPresented = false
    awaitingPresentation = false
    stopMonitoring()
    button()?.highlight(false)
    panel.orderOut(nil)
    panel.onCancel = nil
  }

  /// The status item's screen, or the main screen while the item has no window on a screen.
  static func systemScreen(for button: NSButton?) -> MenuPanelScreen? {
    (button?.window?.screen ?? NSScreen.main).map {
      MenuPanelScreen(frame: $0.frame, visibleFrame: $0.visibleFrame)
    }
  }

  func refreshGeometry() {
    guard let screen = screen(button()) else { return }
    let available = max(1, screen.visibleFrame.height - 40)
    if maxHeight != available {
      maxHeight = available
      if host != nil { rebuildContent() }
    }
    position()
  }

  private func rebuildContent() {
    host.rootView = AnyView(
      PanelView(
        model: model, maxHeight: maxHeight,
        onHeightChange: { [weak self] height in
          guard let self else { return }
          self.contentHeight = ceil(height)
          self.hasMeasuredContent = true
          self.position()
          if self.awaitingPresentation { self.finishPresentation() }
        }
      )
      .environment(\.controlActiveState, .key)
      .id(contentID))
  }

  private func anchor() -> NSRect? {
    guard let button = button(), let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  private func position() {
    guard let anchor = anchor(), let screen = screen(button()) else { return }
    let frame = MenuPanelPlacement.frame(
      anchor: anchor, visibleFrame: screen.visibleFrame,
      size: NSSize(width: PanelView.width, height: min(contentHeight, maxHeight)))
    guard panel.frame != frame else { return }
    panel.setFrame(frame, display: panel.isVisible, animate: false)
    panel.invalidateShadow()
  }

  private func finishPresentation() {
    guard isPresented, awaitingPresentation else { return }
    awaitingPresentation = false
    animateOpacity(to: 1, duration: 0.12)
  }

  private func animateOpacity(
    to value: CGFloat, duration: TimeInterval,
    completion: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    guard !reduceMotion() else {
      panel.alphaValue = value
      completion()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().alphaValue = value
    } completionHandler: {
      MainActor.assumeIsolated { completion() }
    }
  }

  private func startMonitoring() {
    stopMonitoring()
    if let window = button()?.window {
      for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
        anchorObservers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGeometry() }
          })
      }
    }
    guard monitorsSystemEvents else { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: mask,
      handler: { [weak self] event in
        MainActor.assumeIsolated {
          self?.handleClick(eventWindow: event.window, at: NSEvent.mouseLocation)
        }
        return event
      })
    {
      monitors.append(local)
    }
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: mask,
      handler: { [weak self] _ in
        MainActor.assumeIsolated { self?.handleClick(eventWindow: nil, at: NSEvent.mouseLocation) }
      })
    {
      monitors.append(global)
    }
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
    ] {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
          let ownActivation =
            (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .processIdentifier == ProcessInfo.processInfo.processIdentifier
          guard !ownActivation else { return }
          MainActor.assumeIsolated { self?.hide() }
        })
    }
  }

  func handleClick(eventWindow: NSWindow?, at point: NSPoint) {
    guard isPresented,
      MenuPanelPlacement.dismisses(
        eventWindow: eventWindow, at: point, panel: panel, anchor: anchor(),
        screenTop: screen(button())?.frame.maxY)
    else { return }
    hide()
  }

  private func stopMonitoring() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors.removeAll()
    let center = NSWorkspace.shared.notificationCenter
    for observer in workspaceObservers { center.removeObserver(observer) }
    workspaceObservers.removeAll()
    for observer in anchorObservers { NotificationCenter.default.removeObserver(observer) }
    anchorObservers.removeAll()
  }
}
