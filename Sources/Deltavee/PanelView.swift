import AppKit
import DeltaveeCore
import SwiftUI

struct PanelView: View {
  static let width: CGFloat = 320
  static let cornerRadius: CGFloat = 12
  var model: AppModel
  var maxHeight: CGFloat
  var onHeightChange: (CGFloat) -> Void = { _ in }
  @State private var page: SettingsPage?
  /// The provider chosen in the empty-state menu; the Accounts screen adds it on open.
  @State private var addingProvider: Provider?
  @State private var contentHeight: CGFloat = 0
  @State private var chromeHeight: CGFloat = 0
  @State private var settingsHeight: CGFloat = 1
  private var viewportHeight: CGFloat { max(1, min(contentHeight, maxHeight - chromeHeight)) }
  private var panelHeight: CGFloat { viewportHeight + chromeHeight }
  private var activeHeight: CGFloat { page == nil ? panelHeight : settingsHeight }
  var body: some View {
    Group {
      if let page {
        SettingsView(
          model: model, page: page, adding: addingProvider, width: Self.width,
          maxHeight: maxHeight,
          onClose: {
            self.page = nil
            addingProvider = nil
          },
          onHeightChange: { settingsHeight = $0 }
        )
        // A new identity per page so each screen starts from the saved document and top offset.
        .id(page)
      } else {
        accountsPanel
      }
    }.frame(width: Self.width)
      .fixedSize(horizontal: false, vertical: true)
      // The window keeps its popover material; an opaque fill covers it when transparency is off.
      .background {
        // The material's maskImage does not clip subviews, so the fill follows the same corners.
        if !model.document.settings.transparentPanel {
          RoundedRectangle(cornerRadius: Self.cornerRadius, style: .circular)
            .fill(Color(nsColor: .windowBackgroundColor))
        }
      }
      .onChange(of: activeHeight, initial: true) { _, height in
        // Present only after both measurements exist; never fade in an initial one-point panel.
        guard page != nil || (contentHeight > 0 && chromeHeight > 0) else { return }
        onHeightChange(height)
      }
      .environment(\.locale, Locale(identifier: "en_US"))
  }
  private var accountsPanel: some View {
    let accounts = model.document.accounts.sorted { $0.order < $1.order }
    return VStack(alignment: .leading, spacing: 0) {
      if let notice = model.notice {
        VStack(spacing: 0) {
          HStack {
            Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") { model.notice = nil }
          }.foregroundStyle(.red).padding(12)
          Divider()
        }.background {
          GeometryReader { geometry in
            Color.clear.preference(key: PanelChromeHeightKey.self, value: geometry.size.height)
          }
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if model.updates.showsNotice {
            UpdateNoticeView(
              state: model.updates.state, showsStatus: model.updates.hasRequestedCheck
            ).padding(16)
            Divider()
          }
          if model.document.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("No accounts yet. Sign in with each provider's CLI, then add the account.")
                .fixedSize(horizontal: false, vertical: true)
              // Choosing a provider adds the account and opens its card for the directory and label.
              Menu("Add Account") {
                Button("Claude") { open(.accounts, adding: .anthropic) }
                Button("Codex") { open(.accounts, adding: .openai) }
              }.fixedSize()
            }.font(.callout).foregroundStyle(.secondary).padding(16)
          }
          ForEach(accounts) { account in
            AccountRow(
              account: account, state: model.states[account.id] ?? .neverFetched,
              mode: model.document.settings.mode, now: model.now,
              resetTimeMode: model.document.settings.resetTimeMode,
              updatedTimeMode: model.document.settings.updatedTimeMode,
              timeFormat: model.document.settings.timeFormat,
              canAccept: model.pendingIdentities[account.id] != nil,
              refreshing: model.refreshingAccountIDs.contains(account.id),
              heldUntil: model.isRateLimitHeld(account.id, now: model.now)
                ? model.rateLimitHolds[account.id] : nil,
              accept: { model.acceptIdentity(account.id) },
              refresh: { model.refresh(accountID: account.id) }
            ).padding(AccountMetaLine.rowInset)
            if account.id != accounts.last?.id {
              Divider().padding(.horizontal, 16)
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { geometry in
              Color.clear.preference(key: PanelContentHeightKey.self, value: geometry.size.height)
            }
          }
      }.frame(height: viewportHeight)
        .scrollDisabled(contentHeight <= viewportHeight)
      VStack(spacing: 0) {
        Divider()
        VStack(spacing: 2) {
          Button(action: { model.refresh() }) {
            actionLabel("Refresh", symbol: "arrow.clockwise", shortcut: "⌘R")
          }
          .keyboardShortcut("r")
          // Rate-limited accounts are skipped, so a refresh with every account held sends nothing.
          .disabled(
            !model.refreshingAccountIDs.isEmpty
              || model.document.accounts.allSatisfy {
                model.isRateLimitHeld($0.id, now: model.now)
              })
          // The immediate action stands apart from the screens that replace the panel.
          Divider().padding(.vertical, 2)
          Button(action: { open(.accounts) }) {
            actionLabel("Accounts…", symbol: "person.2", shortcut: "⇧⌘A")
          }.keyboardShortcut("a", modifiers: [.command, .shift])
          Button(action: { open(.settings) }) {
            actionLabel("Settings…", symbol: "gearshape", shortcut: "⌘,")
          }.keyboardShortcut(",")
          Button(action: { Task { await model.updates.checkNow() } }) {
            actionLabel("Check for Updates", symbol: "arrow.triangle.2.circlepath", shortcut: "")
          }
          .disabled(model.updates.state.status.isChecking)
          .help("Check GitHub for a new release. Downloads and installation are manual.")
          Divider().padding(.vertical, 2)
          Button(action: { NSApp.terminate(nil) }) {
            actionLabel("Quit Deltavee", symbol: "power", shortcut: "⌘Q")
          }.keyboardShortcut("q")
        }.buttonStyle(MenuActionStyle()).padding(6)
      }.background {
        GeometryReader { geometry in
          Color.clear.preference(key: PanelChromeHeightKey.self, value: geometry.size.height)
        }
      }
    }.frame(width: Self.width)
      .fixedSize(horizontal: false, vertical: true)
      .onPreferenceChange(PanelContentHeightKey.self) { contentHeight = $0 }
      .onPreferenceChange(PanelChromeHeightKey.self) { chromeHeight = $0 }
  }
  /// Starts the screen at the current panel height so the window resizes from where it is.
  private func open(_ page: SettingsPage, adding provider: Provider? = nil) {
    settingsHeight = panelHeight
    addingProvider = provider
    self.page = page
  }
  private func actionLabel(_ title: String, symbol: String, shortcut: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).frame(width: 16)
      Text(title)
      Spacer()
      Text(shortcut).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

private enum PanelContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private enum PanelChromeHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private struct MenuActionStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13))
      .padding(.horizontal, 10).frame(minHeight: 30)
      .background(
        (hovered || configuration.isPressed) && enabled ? Color.primary.opacity(0.09) : .clear,
        in: RoundedRectangle(cornerRadius: 5)
      )
      .contentShape(Rectangle())
      .opacity(enabled ? 1 : 0.45)
      .onHover { hovered = $0 }
  }
}

// Explicit SwiftUI fills keep the requested quota colors visible in inactive menu windows too.
private struct QuotaProgressStyle: ProgressViewStyle {
  let color: Color
  func makeBody(configuration: Configuration) -> some View {
    if let fraction = configuration.fractionCompleted, fraction.isFinite {
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.secondary.opacity(0.15))
          Capsule().fill(color)
            .frame(width: geometry.size.width * min(1, max(0, fraction)))
        }
      }.frame(height: 6)
    }
  }
}

/// The reset and Updated times under an account's weekly limit.
struct AccountMetaLine: View {
  /// Horizontal padding of an account row on each side.
  static let rowInset: CGFloat = 16
  let snapshot: QuotaSnapshot
  let now: Date
  let resetTimeMode: TimeDisplayMode
  let updatedTimeMode: TimeDisplayMode
  let timeFormat: TimeFormat
  var body: some View {
    HStack(spacing: 8) {
      if let reset = snapshot.weeklyResetsAt {
        Text(
          QuotaPresentation.compactResetText(
            reset, mode: resetTimeMode, now: now, timeFormat: timeFormat)
        )
        .help(
          QuotaPresentation.resetText(reset, mode: .absolute, now: now, timeFormat: timeFormat)
        )
        .accessibilityLabel(
          QuotaPresentation.resetText(
            reset, mode: resetTimeMode, now: now, timeFormat: timeFormat))
      }
      Spacer(minLength: 0)
      Text(
        QuotaPresentation.compactUpdatedText(
          snapshot, mode: updatedTimeMode, now: now, timeFormat: timeFormat)
      )
      .help(QuotaPresentation.observationDetails(snapshot, timeFormat: timeFormat))
      .accessibilityLabel(
        QuotaPresentation.updatedText(
          snapshot, mode: updatedTimeMode, now: now, timeFormat: timeFormat))
    }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
  }
}

/// The line under the meta line: staleness under the reset time and the rate-limit note under
/// the Updated time, matching the columns above. Absent when neither applies.
struct AccountStatusLine: View {
  let stale: Bool
  let heldUntil: Date?
  let now: Date
  let resetTimeMode: TimeDisplayMode
  let timeFormat: TimeFormat
  var body: some View {
    if stale, let heldUntil {
      // A resume time on another day can be too long to share the line; then the stale note
      // moves to its own line below, still under the reset time.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          staleNote
          Spacer(minLength: 0)
          note(heldUntil)
        }
        VStack(spacing: 2) {
          HStack {
            Spacer(minLength: 0)
            note(heldUntil)
          }
          HStack {
            staleNote
            Spacer(minLength: 0)
          }
        }
      }
    } else if stale {
      HStack {
        staleNote
        Spacer(minLength: 0)
      }
    } else if let heldUntil {
      HStack {
        Spacer(minLength: 0)
        note(heldUntil)
      }
    }
  }
  private var staleNote: some View {
    Text("More than 1 hour old").font(.caption2).foregroundStyle(.orange).lineLimit(1)
      .fixedSize()
  }
  private func note(_ release: Date) -> some View {
    RateLimitNote(release: release, now: now, resetTimeMode: resetTimeMode, timeFormat: timeFormat)
      .fixedSize()
  }
}

/// Right-aligned under the Updated time while an account waits out a rate limit; one line at panel width.
struct RateLimitNote: View {
  let release: Date
  let now: Date
  let resetTimeMode: TimeDisplayMode
  let timeFormat: TimeFormat
  var body: some View {
    Text(
      QuotaPresentation.rateLimitText(
        release, mode: resetTimeMode, now: now, timeFormat: timeFormat)
    )
    .font(.caption2).foregroundStyle(.orange).monospacedDigit().lineLimit(1)
    .help(
      QuotaPresentation.rateLimitText(release, mode: .absolute, now: now, timeFormat: timeFormat))
  }
}

private struct AccountRow: View {
  let account: Account
  let state: AccountState
  let mode: PercentMode
  let now: Date
  let resetTimeMode: TimeDisplayMode
  let updatedTimeMode: TimeDisplayMode
  let timeFormat: TimeFormat
  let canAccept: Bool
  let refreshing: Bool
  /// Rate-limit release time; manual refresh stays disabled until then.
  let heldUntil: Date?
  let accept: () -> Void
  let refresh: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        Image(nsImage: MenuBarTitle.icon(for: account.provider))
          .resizable().frame(width: MenuBarTitle.panelIconSize, height: MenuBarTitle.panelIconSize)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(account.provider.displayName).font(.headline)
          if let label = account.displayLabel {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .accessibilityElement(children: .ignore)
        .help(QuotaPresentation.accountAccessibilityLabel(account))
        .accessibilityLabel(QuotaPresentation.accountAccessibilityLabel(account))
        Spacer(minLength: 4)
        Button(action: refresh) {
          Group {
            if refreshing {
              ProgressView().controlSize(.mini)
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }.frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.borderless).disabled(refreshing || heldUntil != nil)
          .help(
            heldUntil.map {
              QuotaPresentation.rateLimitText(
                $0, mode: .absolute, now: now, timeFormat: timeFormat)
            } ?? "Refresh this account"
          )
          .accessibilityLabel("Refresh \(QuotaPresentation.accountAccessibilityLabel(account))")
      }
      HStack(alignment: .firstTextBaseline) {
        Text("Weekly quota").foregroundStyle(.secondary)
        Spacer()
        Text(
          "\(IconRenderer.percentage(state.lastSuccess?.weeklyUsedPercent, mode: mode)) \(mode == .used ? "used" : "remaining")"
        )
        .monospacedDigit().fontWeight(.medium)
      }.font(.callout)
      if let used = state.lastSuccess?.weeklyUsedPercent,
        let severity = QuotaPresentation.usageSeverity(usedPercent: used)
      {
        ProgressView(value: mode == .used ? used : 100 - used, total: 100)
          .progressViewStyle(
            QuotaProgressStyle(color: Color(nsColor: QuotaPresentation.usageColor(severity)))
          )
          .accessibilityLabel(mode == .used ? "Weekly quota used" : "Weekly quota remaining")
      }
      // While held, the rate-limit note under the Updated time replaces the failure message.
      if heldUntil == nil, state.hasFailure || state.lastSuccess == nil {
        Text(state.message).font(.caption).foregroundStyle(state.hasFailure ? .orange : .secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let snapshot = state.lastSuccess {
        if snapshot.weeklyUsedPercent == nil { Text("Weekly quota unavailable").font(.caption) }
        VStack(spacing: 2) {
          AccountMetaLine(
            snapshot: snapshot, now: now, resetTimeMode: resetTimeMode,
            updatedTimeMode: updatedTimeMode, timeFormat: timeFormat
          )
          .lineLimit(1).minimumScaleFactor(0.85)
          AccountStatusLine(
            stale: snapshot.isStale(now: now), heldUntil: heldUntil, now: now,
            resetTimeMode: resetTimeMode, timeFormat: timeFormat)
        }
      }
      if state.lastSuccess == nil, let heldUntil {
        RateLimitNote(
          release: heldUntil, now: now, resetTimeMode: resetTimeMode, timeFormat: timeFormat
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
      if case .identityChanged = state {
        Button("Use New Account (Reset History)", action: accept).disabled(!canAccept)
      }
      if state.showsCLICommand {
        Text(account.signInCommand)
          .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
      }
    }
  }

}
