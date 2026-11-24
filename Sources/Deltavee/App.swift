import AppKit
import DeltaveeCore
import ServiceManagement
import SwiftUI
import os

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
  private let model = AppModel()
  private var item: NSStatusItem!
  private lazy var panelController = MenuPanelController(
    model: model, button: { [weak self] in self?.item?.button })
  private var timer: Timer?
  private var renderTask: Task<Void, Never>?
  private var terminationTask: Task<Void, Never>?
  func applicationDidFinishLaunching(_ notification: Notification) {
    refreshClaudeStatuslineHook()
    NSApp.setActivationPolicy(.accessory)
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.target = self
    item.button?.action = #selector(togglePanel)
    _ = panelController
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenParametersChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    model.refresh()
    model.updates.start()
    render()
    // Redraws the status item whenever an input of `render()` changes, whichever path mutated it.
    let model = model
    let inputs = Observations { (model.document, model.states, model.now) }
    renderTask = Task { [weak self] in
      for await _ in inputs { self?.render() }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.model.tick() }
    }
  }

  private func refreshClaudeStatuslineHook() {
    guard
      let bundled = Bundle.main.url(
        forResource: ClaudeStatuslineHook.filename, withExtension: nil)
    else { return }
    let installed = Paths.applicationSupport
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent(ClaudeStatuslineHook.filename)
    do {
      try ClaudeStatuslineHook.refresh(bundled: bundled, installed: installed)
    } catch {
      let logger = Logger(subsystem: "dev.pers0n4.deltavee", category: "statusline")
      logger.error("Could not sync the Claude statusline hook: \(error)")
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationTask == nil {
      terminationTask = Task { [model] in
        await model.updates.stop()
        sender.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) {
    timer?.invalidate()
    renderTask?.cancel()
    panelController.shutdown()
  }
  @objc private func systemDidWake() {
    model.systemDidWake()
  }
  @objc private func screenParametersChanged() {
    panelController.refreshGeometry()
  }
  private func render() {
    panelController.apply(theme: model.document.settings.theme)
    let parts = IconRenderer.parts(
      accounts: model.document.accounts, states: model.states, mode: model.document.settings.mode,
      now: model.now, emails: model.detectedEmails)
    item.button?.attributedTitle = MenuBarTitle.attributedString(
      parts: parts, colorUsage: model.document.settings.colorMenuBarUsage)
    let description = MenuBarTitle.accessibilityDescription(
      parts: parts, mode: model.document.settings.mode)
    item.button?.toolTip = description
    item.button?.setAccessibilityLabel(description)
  }
  @objc private func togglePanel() {
    model.tick()
    panelController.toggle()
  }
}

/// `Deltavee --login-item <status|enable|disable>`: same SMAppService calls as the panel toggle, for scripted checks.
enum LoginItemCommand {
  static func run(_ action: String) -> Int32 {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      print("error: run the executable inside the .app bundle")
      return 2
    }
    do {
      switch action {
      case "status": break
      case "enable": try SMAppService.mainApp.register()
      case "disable": try SMAppService.mainApp.unregister()
      default:
        print("usage: --login-item <status|enable|disable>")
        return 2
      }
    } catch {
      print("error: \((error as NSError).domain) \((error as NSError).code)")
      return 1
    }
    print("status: \(describe(SMAppService.mainApp.status))")
    return 0
  }
  static func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: return "enabled"
    case .notRegistered: return "notRegistered"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
  }
}

@main
struct DeltaveeApp {
  @MainActor static func main() {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "--login-item" {
      exit(LoginItemCommand.run(arguments[2]))
    }
    let application = NSApplication.shared
    let delegate = MenuBarController()
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
  }
}
