import AppKit
import DeltaveeCore
import Foundation
import ServiceManagement
import SwiftUI

/// A text field that applies its value on Return, when editing ends (focus loss), or when it
/// leaves the screen, not on every keystroke.
private struct CommitTextField: View {
  let title: String
  @Binding var value: String
  let onCommit: () -> Void
  @State private var text: String

  init(_ title: String, value: Binding<String>, onCommit: @escaping () -> Void) {
    self.title = title
    _value = value
    self.onCommit = onCommit
    _text = State(initialValue: value.wrappedValue)
  }

  var body: some View {
    TextField(title, text: $text)
      .onSubmit(commit)
      // AppKit ends editing on Return, Tab, and focus loss. Only one field edits at a time, so
      // a field whose text differs from its value is the one that just ended editing.
      .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification))
    {
      _ in commit()
    }
      .onChange(of: value) { old, new in if text == old { text = new } }
      .onDisappear(perform: commit)
  }

  private func commit() {
    guard text != value else { return }
    value = text
    onCommit()
    // Show the applied value, e.g. a clamped interval, or restore it when input was rejected.
    // Deferred: the field editor that is ending editing would overwrite a same-turn update.
    Task { @MainActor in text = value }
  }
}

/// A native menu that fills its assigned column instead of sizing to the selected title.
private struct SettingsPicker<Value: Equatable>: NSViewRepresentable {
  let title: String
  @Binding var selection: Value
  let options: [(String, Value)]
  /// Set as the AppKit tool tip so tests can read it without hovering, unlike SwiftUI `.help`.
  var help: String? = nil

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    button.target = context.coordinator
    button.action = #selector(Coordinator.select(_:))
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.parent = self
    if button.itemTitles != options.map(\.0) {
      button.removeAllItems()
      button.addItems(withTitles: options.map(\.0))
    }
    button.selectItem(at: options.firstIndex { $0.1 == selection } ?? -1)
    button.setAccessibilityLabel(title)
    button.toolTip = help
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context
  ) -> CGSize? {
    CGSize(
      width: proposal.width ?? nsView.intrinsicContentSize.width,
      height: nsView.intrinsicContentSize.height)
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: SettingsPicker
    init(_ parent: SettingsPicker) { self.parent = parent }

    @objc func select(_ sender: NSPopUpButton) {
      guard parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
      parent.selection = parent.options[sender.indexOfSelectedItem].1
    }
  }
}

/// Shared policy disclosure in the provider settings cards.
struct SettingsTermsDetails<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 10)
            .accessibilityHidden(true)
          Text("Terms and details")
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      if isExpanded {
        content()
      }
    }.font(.caption)
  }
}

/// The two screens that replace the usage panel: account management and app settings.
enum SettingsPage: Equatable {
  case accounts, settings
  var title: String {
    switch self {
    case .accounts: "Accounts"
    case .settings: "Settings"
    }
  }
}

struct SettingsView: View {
  var model: AppModel
  let page: SettingsPage
  let width: CGFloat
  let maxHeight: CGFloat
  let onClose: () -> Void
  let onHeightChange: (CGFloat) -> Void
  @State private var draft: SettingsDraft
  @State private var lastApplied: AccountDocument
  @State private var pendingRemoval: UUID?
  @State private var contentHeight: CGFloat = 0
  @State private var chromeHeight: CGFloat = 0
  @State private var reportedHeight: CGFloat = 0
  @State private var expandedAccounts: Set<UUID>
  @State private var cardHeights: [UUID: CGFloat] = [:]
  @State private var cardDrag: AccountCardDrag?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private static let accountSpacing: CGFloat = 12
  private static let accountListSpace = "accountList"

  private var cardMotion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }

  private var accountHeights: [CGFloat] {
    draft.document.accounts.map { cardHeights[$0.id] ?? 0 }
  }

  private var cardDestination: Int? {
    guard let cardDrag else { return nil }
    return AccountReordering.destination(
      heights: accountHeights, source: cardDrag.source, translation: cardDrag.translation,
      spacing: Self.accountSpacing)
  }

  private var viewportHeight: CGFloat {
    min(contentHeight, max(0, maxHeight - chromeHeight))
  }

  private var totalHeight: CGFloat {
    min(maxHeight, chromeHeight + viewportHeight)
  }

  init(
    model: AppModel, page: SettingsPage, adding provider: Provider? = nil, width: CGFloat,
    maxHeight: CGFloat, onClose: @escaping () -> Void,
    onHeightChange: @escaping (CGFloat) -> Void
  ) {
    self.model = model
    self.page = page
    self.width = width
    self.maxHeight = maxHeight
    self.onClose = onClose
    self.onHeightChange = onHeightChange
    var draft = SettingsDraft(model.document)
    _lastApplied = State(initialValue: draft.applicableDocument(current: model.document))
    // An account added from the empty panel starts expanded; `onAppear` applies it.
    var expanded: Set<UUID> = []
    if let provider {
      draft.add(provider)
      if let id = draft.document.accounts.last?.id { expanded.insert(id) }
    }
    _draft = State(initialValue: draft)
    _expandedAccounts = State(initialValue: expanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Button(action: onClose) {
          Image(systemName: "chevron.left")
            .frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.borderless)
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Back")
          .help("Back (Esc)")
        Text(page.title).font(.headline)
        Spacer()
      }.padding(12)
        .background {
          GeometryReader { geometry in
            Color.clear.preference(key: SettingsChromeHeightKey.self, value: geometry.size.height)
          }
        }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          switch page {
          case .accounts: accountsSection
          case .settings:
            generalSection
            collectionSection
          }
        }.padding(.horizontal, 12).padding(.bottom, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { geometry in
              Color.clear.preference(
                key: SettingsContentHeightKey.self, value: geometry.size.height)
            }
          }
      }
      .frame(height: viewportHeight)
      .scrollDisabled(contentHeight <= viewportHeight)
    }.frame(width: width)
      .fixedSize(horizontal: false, vertical: true)
      .onPreferenceChange(SettingsContentHeightKey.self) { contentHeight = ceil($0) }
      .onPreferenceChange(SettingsChromeHeightKey.self) { chromeHeight = ceil($0) }
      .onPreferenceChange(AccountCardHeightsKey.self) { cardHeights = $0 }
      .onAppear(perform: apply)
      .onChange(of: draft.document) { apply() }
      .onChange(of: totalHeight, initial: true) { _, height in
        guard contentHeight > 0, chromeHeight > 0, height != reportedHeight else { return }
        reportedHeight = height
        onHeightChange(height)
      }
      .environment(\.locale, Locale(identifier: "en_US"))
  }

  /// Applies the draft immediately. Text fields only write to the draft once editing ends.
  private func apply() {
    let document = draft.applicableDocument(current: model.document)
    guard document != lastApplied else { return }
    lastApplied = document
    model.save(document)
  }

  private var accountsSection: some View {
    VStack(alignment: .leading, spacing: Self.accountSpacing) {
      HStack {
        Text("\(draft.document.accounts.count) accounts").font(.subheadline).fontWeight(.medium)
        Spacer()
        if !draft.document.accounts.isEmpty {
          Button(expandedAccounts.isEmpty ? "Expand All" : "Collapse All") {
            expandedAccounts =
              expandedAccounts.isEmpty ? Set(draft.document.accounts.map(\.id)) : []
          }.font(.caption).buttonStyle(.borderless)
            .keyboardShortcut("e", modifiers: [.command, .option])
            .help("Expand or collapse all account details (⌥⌘E)")
        }
      }
      helpText("Drag the handles to reorder.")
      if draft.document.accounts.isEmpty {
        Text("No accounts yet. Add a Claude or Codex account below.")
          .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
      }
      ForEach($draft.document.accounts) { account in
        accountCard(account)
      }
      Menu {
        Button("Claude") {
          draft.add(.anthropic)
          expandLastAccount()
        }
        Button("Codex") {
          draft.add(.openai)
          expandLastAccount()
        }
      } label: {
        Label("Add Account", systemImage: "plus").frame(maxWidth: .infinity)
      }
      if draft.hasMissingDirectory {
        Label(
          "Every account needs a configuration directory. Until then, the last directory is kept.",
          systemImage: "exclamationmark.circle"
        )
        .font(.caption).foregroundStyle(.orange)
      }
    }.coordinateSpace(name: Self.accountListSpace)
  }

  private func cardOffset(_ id: UUID) -> CGFloat {
    guard let cardDrag, let destination = cardDestination else { return 0 }
    if cardDrag.id == id { return cardDrag.translation }
    guard let index = draft.document.accounts.firstIndex(where: { $0.id == id }) else { return 0 }
    return AccountReordering.offset(
      index: index, source: cardDrag.source, destination: destination,
      shift: (cardHeights[cardDrag.id] ?? 0) + Self.accountSpacing)
  }

  private func dragCard(_ id: UUID, translation: CGFloat) {
    if cardDrag == nil {
      guard let source = draft.document.accounts.firstIndex(where: { $0.id == id }) else { return }
      cardDrag = AccountCardDrag(id: id, source: source, translation: 0)
    }
    cardDrag?.translation = translation
  }

  private func dropCard() {
    guard let cardDrag, let destination = cardDestination else { return }
    // One transaction: the layout move and the offset reset cancel out for resting cards, and
    // the dragged card settles from the pointer into its new slot.
    withAnimation(cardMotion) {
      draft.move(cardDrag.id, to: destination)
      self.cardDrag = nil
    }
  }

  private func accountCard(_ account: Binding<Account>) -> some View {
    let value = account.wrappedValue
    let accessibilityLabel = QuotaPresentation.accountAccessibilityLabel(value)
    let lifted = cardDrag?.id == value.id
    return GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        accountHeader(value)
        if expandedAccounts.contains(value.id) {
          Divider()
          accountDetails(account)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
    .background {
      GeometryReader { geometry in
        Color.clear.preference(
          key: AccountCardHeightsKey.self, value: [value.id: geometry.size.height])
      }
    }
    .background {
      // The lifted card is opaque so the cards sliding underneath do not show through.
      if lifted {
        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor))
      }
    }
    .scaleEffect(lifted ? 1.02 : 1)
    .shadow(color: .black.opacity(lifted ? 0.2 : 0), radius: 10, y: 4)
    .offset(y: cardOffset(value.id))
    // Only resting cards animate when the open slot moves; the lifted card tracks the pointer.
    .animation(lifted ? nil : cardMotion, value: cardDestination)
    .zIndex(lifted ? 1 : 0)
    .accessibilityElement(children: .contain)
    .accessibilityActions {
      if draft.canMoveUp(value.id) {
        Button("Move \(accessibilityLabel) earlier") { draft.moveUp(value.id) }
      }
      if draft.canMoveDown(value.id) {
        Button("Move \(accessibilityLabel) later") { draft.moveDown(value.id) }
      }
    }
  }

  private func accountHeader(_ value: Account) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
        .frame(width: 24, height: 32).contentShape(Rectangle())
        .accessibilityLabel("Drag to reorder \(QuotaPresentation.accountAccessibilityLabel(value))")
        .help("Drag above or below another account to change order")
        .gesture(
          DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.accountListSpace))
            .onChanged { dragCard(value.id, translation: $0.translation.height) }
            .onEnded { _ in dropCard() }
        )
      Image(nsImage: MenuBarTitle.icon(for: value.provider))
        .resizable().scaledToFit().frame(width: 16, height: 16).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(value.provider.displayName).font(.headline)
        Text(value.displayLabel ?? URL(fileURLWithPath: value.expandedDirectory).lastPathComponent)
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }.help(value.expandedDirectory)
      Spacer(minLength: 0)
      // Menu bar visibility is a per-account display switch, adjustable without expanding.
      Toggle("Show in menu bar", isOn: showInIcon(value.id))
        .toggleStyle(.switch).controlSize(.mini).labelsHidden().fixedSize()
        .help(value.showInIcon ? "Shown in the menu bar" : "Hidden from the menu bar")
        .accessibilityLabel(
          "Show \(QuotaPresentation.accountAccessibilityLabel(value)) in menu bar")
      Button {
        if !expandedAccounts.insert(value.id).inserted { expandedAccounts.remove(value.id) }
      } label: {
        Image(systemName: expandedAccounts.contains(value.id) ? "chevron.up" : "chevron.down")
          .frame(width: 24, height: 28).contentShape(Rectangle())
      }.buttonStyle(.borderless)
        .accessibilityLabel(
          "\(expandedAccounts.contains(value.id) ? "Collapse" : "Expand") \(QuotaPresentation.accountAccessibilityLabel(value)) details"
        )
    }
  }

  private func showInIcon(_ id: UUID) -> Binding<Bool> {
    accountField(id, \.showInIcon, missing: false)
  }

  /// Binds an account field by ID rather than array index. A removed account's fields can still be
  /// read once more (e.g. a text field committing on disappear); they then read `missing` and
  /// ignore writes instead of indexing past the end of the account array.
  private func accountField<Value>(
    _ id: UUID, _ keyPath: WritableKeyPath<Account, Value>, missing: Value
  ) -> Binding<Value> {
    Binding(
      get: { draft.document.accounts.first { $0.id == id }?[keyPath: keyPath] ?? missing },
      set: { value in
        guard let index = draft.document.accounts.firstIndex(where: { $0.id == id }) else { return }
        draft.document.accounts[index][keyPath: keyPath] = value
      })
  }

  private func accountDetails(_ account: Binding<Account>) -> some View {
    let value = account.wrappedValue
    let label = QuotaPresentation.accountAccessibilityLabel(value)
    return VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Label (optional)").font(.caption).foregroundStyle(.secondary)
        CommitTextField(
          "Shown under the provider, e.g. Work", value: accountField(value.id, \.name, missing: ""),
          onCommit: apply
        )
        .textFieldStyle(.roundedBorder).accessibilityLabel("Optional label for \(label)")
      }
      // The provider is chosen when adding and fixed afterwards; the card header shows it.
      VStack(alignment: .leading, spacing: 5) {
        Text("Configuration directory").font(.caption).foregroundStyle(.secondary)
        CommitTextField(
          value.provider == .anthropic ? "~/.claude" : "~/.codex",
          value: accountField(value.id, \.configDir, missing: ""),
          onCommit: apply
        )
        .font(.system(.callout, design: .monospaced)).textFieldStyle(.roundedBorder)
        .accessibilityLabel("Configuration directory for \(label)")
      }
      Divider()
      // Destructive action last and trailing, apart from the fields; confirmed in place.
      if pendingRemoval == value.id {
        HStack(spacing: 8) {
          Text("Remove this account?").font(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("Cancel") { pendingRemoval = nil }
            .accessibilityLabel("Keep \(label)")
          Button("Remove", role: .destructive) {
            pendingRemoval = nil
            expandedAccounts.remove(value.id)
            draft.remove(value.id)
          }.accessibilityLabel("Confirm removing \(label)")
        }.controlSize(.small)
      } else {
        HStack {
          Spacer(minLength: 0)
          Button(role: .destructive) {
            pendingRemoval = value.id
          } label: {
            Label("Remove Account…", systemImage: "trash")
          }
          .buttonStyle(.borderless).font(.caption).foregroundStyle(.red)
          .accessibilityLabel("Remove \(label)")
        }
      }
    }
  }

  private func expandLastAccount() {
    if let id = draft.document.accounts.last?.id { expandedAccounts.insert(id) }
  }

  private var generalSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("General").font(.headline).padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
      GroupBox("Appearance") {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
          GridRow {
            Text("Theme").frame(maxWidth: .infinity, alignment: .leading)
            SettingsPicker(
              title: "Theme", selection: $draft.document.settings.theme,
              options: [("System", .system), ("Light", .light), ("Dark", .dark)]
            ).frame(width: 124)
          }
          GridRow {
            Text("Translucent panel").frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Translucent panel", isOn: $draft.document.settings.transparentPanel)
              .toggleStyle(.switch).controlSize(.small).labelsHidden()
              .fixedSize()
              // Shares the column with pop-up menus; switches stay at its trailing edge.
              .gridCellAnchor(.trailing)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("Usage") {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
          GridRow {
            Text("Show usage as").frame(maxWidth: .infinity, alignment: .leading)
            SettingsPicker(
              title: "Show usage as", selection: $draft.document.settings.mode,
              options: [("Remaining", .remaining), ("Used", .used)]
            ).frame(width: 124)
          }
          // Only the menu bar text is optional; the panel graph always uses these colors.
          GridRow {
            Text("Color menu bar usage").frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Color menu bar usage", isOn: $draft.document.settings.colorMenuBarUsage)
              .toggleStyle(.switch).controlSize(.small).labelsHidden()
              .fixedSize()
              .gridCellAnchor(.trailing)
          }
          // The legend spans both columns so it never widens the label column.
          GridRow {
            usageColorLegend.gridCellColumns(2).padding(.top, -6)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("Time") {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
          GridRow {
            Text("Reset time").frame(maxWidth: .infinity, alignment: .leading)
            SettingsPicker(
              title: "Reset time", selection: $draft.document.settings.resetTimeMode,
              options: [("Date & Time", .absolute), ("Countdown", .relative)]
            ).frame(width: 124)
          }
          GridRow {
            Text("Updated time").frame(maxWidth: .infinity, alignment: .leading)
            SettingsPicker(
              title: "Updated time", selection: $draft.document.settings.updatedTimeMode,
              options: [("Date & Time", .absolute), ("Time Ago", .relative)]
            ).frame(width: 124)
          }
          GridRow {
            Text("Clock format").frame(maxWidth: .infinity, alignment: .leading)
            SettingsPicker(
              title: "Clock format", selection: $draft.document.settings.timeFormat,
              options: [("System", .auto), ("12-Hour", .hour12), ("24-Hour", .hour24)],
              help:
                "Applies to tooltips and Date & Time displays. System follows the Mac's 12-hour or 24-hour clock setting"
            ).frame(width: 124)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("Startup") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Launch at login").frame(maxWidth: .infinity, alignment: .leading)
            Toggle(
              "Launch at login",
              isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })
            )
            .toggleStyle(.switch).controlSize(.small).labelsHidden().fixedSize()
          }
          if model.loginNeedsApproval {
            HStack(spacing: 6) {
              Label("Needs approval in Login Items.", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
              Spacer(minLength: 0)
              Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open Login Items in System Settings")
            }.font(.caption)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
    }.onAppear { model.refreshLoginStatus() }
  }

  /// Severity colors shared with the weekly graph, labeled in the selected percent mode.
  private var usageColorLegend: some View {
    let mode = draft.document.settings.mode
    return HStack(spacing: 8) {
      ForEach(QuotaPresentation.severityLegend(mode: mode), id: \.label) { threshold, severity in
        HStack(spacing: 3) {
          Circle().fill(Color(nsColor: QuotaPresentation.usageColor(severity)))
            .frame(width: 7, height: 7)
          Text(threshold).lineLimit(1).fixedSize()
        }
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(QuotaPresentation.severityLegendAccessibilityLabel(mode: mode))
  }

  private var collectionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Data collection").font(.headline).padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
      refreshSection
      GroupBox("Claude") {
        VStack(alignment: .leading, spacing: 10) {
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
              Text("Source").frame(maxWidth: .infinity, alignment: .leading)
              SettingsPicker(
                title: "Source", selection: $draft.document.settings.claudeSource,
                options: [
                  ("OAuth + Statusline", .oauthWithStatusline),
                  ("Statusline Only", .statuslineOnly),
                ],
                help: "Unofficial OAuth + statusline fallback, or local statusline only"
              ).frame(width: 164)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          cliPathField("Claude", value: $draft.document.settings.claudePath)
          if draft.document.settings.claudeSource == .statuslineOnly {
            helpText("Reads local captures only. No tokens or direct provider requests.")
            helpText(
              "New observations require Claude Code. Refresh only rereads the latest capture.")
          } else {
            Label(
              "Private OAuth requests may violate provider terms.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
          }
          SettingsTermsDetails {
            VStack(alignment: .leading, spacing: 8) {
              helpText(
                "OAuth + Statusline uses an unofficial endpoint with statusline fallback. Statusline Only uses local observations. Neither mode guarantees account safety."
              )
              Link(
                "Legal and compliance details",
                destination: URL(string: "https://code.claude.com/docs/en/legal-and-compliance")!)
            }.font(.caption).padding(.top, 6)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("Codex") {
        VStack(alignment: .leading, spacing: 8) {
          cliPathField("Codex", value: $draft.document.settings.codexPath)
          SettingsTermsDetails {
            VStack(alignment: .leading, spacing: 8) {
              helpText(
                "OpenAI permits continued app-server authentication for local or open-source apps, not commercial or hosted services. Account safety is not guaranteed."
              )
              Link(
                "Codex authentication terms",
                destination: URL(
                  string: "https://learn.chatgpt.com/docs/app-server#auth-endpoints")!)
            }.font(.caption).padding(.top, 6)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
    }
  }

  private var refreshSection: some View {
    GroupBox("Refresh") {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Interval").frame(maxWidth: .infinity, alignment: .leading)
          SettingsPicker(
            title: "Refresh interval", selection: $draft.document.settings.intervalSeconds,
            options: DeltaveeCore.Settings.intervalChoices.map { ("\(Int($0) / 60) min", $0) }
          ).frame(width: 124)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
  }

  private func cliPathField(_ name: String, value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("CLI path (optional)").font(.caption).foregroundStyle(.secondary)
      CommitTextField("Auto-detect", value: value, onCommit: apply)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("\(name) CLI path; leave blank to auto-detect")
    }
  }

  private func helpText(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private enum SettingsContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private enum SettingsChromeHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value += nextValue()
  }
}
