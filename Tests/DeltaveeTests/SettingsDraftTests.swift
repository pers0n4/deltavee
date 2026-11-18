import DeltaveeCore
import Foundation
import XCTest

@testable import Deltavee

final class SettingsDraftTests: XCTestCase {
  private func account(_ name: String, order: Int) -> Account {
    Account(
      name: name, provider: .anthropic, configDir: "~/.claude-\(name)",
      showInIcon: name != "B", order: order, identityFingerprint: "identity-\(name)")
  }

  func testMoveUpSwapsAccountsAndPreservesIdentityAndSettings() {
    let first = account("A", order: 4)
    let second = account("B", order: 9)
    var settings = Settings()
    settings.claudeSource = .statuslineOnly
    settings.mode = .remaining
    settings.intervalSeconds = 123
    settings.codexPath = "/custom/codex"
    var draft = SettingsDraft(AccountDocument(accounts: [first, second], settings: settings))

    draft.moveUp(second.id)

    var expectedFirst = first
    var expectedSecond = second
    expectedFirst.order = 1
    expectedSecond.order = 0
    XCTAssertEqual(draft.document.accounts, [expectedSecond, expectedFirst])
    XCTAssertEqual(draft.document.settings, settings)
    XCTAssertFalse(draft.canMoveUp(second.id))
    XCTAssertTrue(draft.canMoveDown(second.id))
  }

  func testMoveDownSwapsOnlyAdjacentAccounts() {
    let accounts = [account("A", order: 2), account("B", order: 5), account("C", order: 8)]
    var draft = SettingsDraft(AccountDocument(accounts: accounts))

    draft.moveDown(accounts[0].id)

    XCTAssertEqual(
      draft.document.accounts.map(\.id), [accounts[1].id, accounts[0].id, accounts[2].id])
    XCTAssertEqual(draft.document.accounts.map(\.order), [0, 1, 2])
    XCTAssertEqual(
      draft.document.accounts.map(\.identityFingerprint),
      ["identity-B", "identity-A", "identity-C"])
  }

  func testMoveToDestinationIndexReordersAndRejectsInvalidMoves() {
    let accounts = (0..<4).map { account("Account \($0)", order: $0 * 5) }
    for (source, destination, expected) in [
      (0, 2, [1, 2, 0, 3]), (3, 0, [3, 0, 1, 2]), (1, 3, [0, 2, 3, 1]), (2, 1, [0, 2, 1, 3]),
    ] {
      var draft = SettingsDraft(AccountDocument(accounts: accounts))
      XCTAssertTrue(draft.move(accounts[source].id, to: destination))
      XCTAssertEqual(draft.document.accounts.map(\.id), expected.map { accounts[$0].id })
      XCTAssertEqual(draft.document.accounts.map(\.order), [0, 1, 2, 3])
    }
    var draft = SettingsDraft(AccountDocument(accounts: accounts))
    XCTAssertFalse(draft.move(accounts[1].id, to: 1))
    XCTAssertFalse(draft.move(accounts[1].id, to: 4))
    XCTAssertFalse(draft.move(accounts[1].id, to: -1))
    XCTAssertFalse(draft.move(UUID(), to: 0))
    XCTAssertEqual(draft.document.accounts.map(\.id), accounts.map(\.id))
  }

  func testInsertionMovesBeforeAndAfterNonadjacentRowsInBothDirections() {
    let accounts = (0..<5).map { account("Account \($0)", order: $0 * 3 + 2) }
    let cases: [(Int, Int, Bool, [Int])] = [
      (0, 3, false, [1, 2, 0, 3, 4]),
      (0, 3, true, [1, 2, 3, 0, 4]),
      (4, 1, false, [0, 4, 1, 2, 3]),
      (4, 1, true, [0, 1, 4, 2, 3]),
      (3, 0, false, [3, 0, 1, 2, 4]),
      (1, 4, true, [0, 2, 3, 4, 1]),
    ]
    var settings = Settings()
    settings.mode = .remaining
    settings.claudeSource = .statuslineOnly
    settings.codexPath = "/fake/custom-codex"
    settings.intervalSeconds = 93
    settings.timeFormat = .hour12
    for (source, target, after, expectedIndices) in cases {
      var draft = SettingsDraft(AccountDocument(accounts: accounts, settings: settings))

      XCTAssertTrue(draft.move(accounts[source].id, relativeTo: accounts[target].id, after: after))

      let expected = expectedIndices.enumerated().map { order, index in
        var value = accounts[index]
        value.order = order
        return value
      }
      XCTAssertEqual(
        draft.document.accounts, expected, "Move \(source) relative to \(target), after: \(after)")
      XCTAssertEqual(draft.document.settings, settings)
    }
  }

  func testRejectedInsertionMovesPreserveUnnormalizedOrdersAndAllMetadata() {
    let accounts = [account("A", order: 4), account("B", order: 9), account("C", order: 17)]
    var draft = SettingsDraft(AccountDocument(accounts: accounts))
    let before = draft.document
    let unknown = UUID()
    let cases = [
      (unknown, accounts[0].id, false), (accounts[0].id, unknown, true),
      (unknown, unknown, false), (accounts[1].id, accounts[1].id, false),
      (accounts[1].id, accounts[1].id, true),
      (accounts[0].id, accounts[1].id, false),
      (accounts[1].id, accounts[0].id, true),
      (accounts[1].id, accounts[2].id, false),
      (accounts[2].id, accounts[1].id, true),
    ]
    for (source, target, after) in cases {
      XCTAssertFalse(draft.move(source, relativeTo: target, after: after))
      XCTAssertEqual(draft.document, before)
    }
    var empty = SettingsDraft(AccountDocument())
    XCTAssertFalse(empty.move(unknown, relativeTo: accounts[0].id, after: true))
    XCTAssertEqual(empty.document, AccountDocument())
    var single = SettingsDraft(AccountDocument(accounts: [accounts[0]]))
    XCTAssertFalse(single.move(accounts[0].id, relativeTo: accounts[0].id, after: true))
    XCTAssertEqual(single.document.accounts, [accounts[0]])
  }

  func testBoundaryAndUnknownIDsDoNotMutateDocument() {
    let accounts = [account("A", order: 4), account("B", order: 8)]
    var draft = SettingsDraft(AccountDocument(accounts: accounts))
    let before = draft.document
    let unknownID = UUID()

    XCTAssertFalse(draft.canMoveUp(accounts[0].id))
    XCTAssertFalse(draft.canMoveDown(accounts[1].id))
    XCTAssertFalse(draft.canMoveUp(unknownID))
    XCTAssertFalse(draft.canMoveDown(unknownID))
    draft.moveUp(accounts[0].id)
    draft.moveDown(accounts[1].id)
    draft.moveUp(unknownID)
    draft.moveDown(unknownID)
    draft.remove(unknownID)

    XCTAssertEqual(draft.document, before)
    var empty = SettingsDraft(AccountDocument())
    empty.moveUp(unknownID)
    empty.moveDown(unknownID)
    empty.remove(unknownID)
    XCTAssertEqual(empty.document, AccountDocument())
    var single = SettingsDraft(AccountDocument(accounts: [accounts[0]]))
    single.moveUp(accounts[0].id)
    single.moveDown(accounts[0].id)
    XCTAssertEqual(single.document.accounts, [accounts[0]])
  }

  func testInitializationUsesStableSavedOrderForTies() {
    let first = account("A", order: 7)
    let second = account("B", order: -2)
    let third = account("C", order: 7)
    let fourth = account("D", order: -2)
    let original = AccountDocument(accounts: [first, second, third, fourth])

    let draft = SettingsDraft(original)

    XCTAssertEqual(draft.document.accounts, [second, fourth, first, third])
    XCTAssertEqual(original.accounts, [first, second, third, fourth])
    XCTAssertEqual(draft.document.settings.claudeSource, original.settings.claudeSource)
  }

  func testMovedOrderPersistsThroughAccountStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AccountStore(directory: directory)
    let accounts = [account("A", order: 4), account("B", order: 8), account("C", order: 12)]
    var draft = SettingsDraft(AccountDocument(accounts: accounts))
    XCTAssertTrue(draft.move(accounts[0].id, relativeTo: accounts[2].id, after: true))

    try store.save(draft.document)
    let loaded = try store.load()

    XCTAssertEqual(loaded, draft.document)
    XCTAssertEqual(loaded.accounts.map(\.order), [0, 1, 2])
    XCTAssertEqual(
      SettingsDraft(loaded).document.accounts.map(\.id),
      [accounts[1].id, accounts[2].id, accounts[0].id])
  }

  func testMovedOrderDrivesMenuBarWithoutShowingHiddenAccounts() {
    let accounts = [account("A", order: 1), account("B", order: 2), account("C", order: 3)]
    var draft = SettingsDraft(AccountDocument(accounts: accounts))
    draft.moveUp(accounts[2].id)
    draft.moveUp(accounts[2].id)

    let parts = IconRenderer.parts(
      accounts: draft.document.accounts, states: [:], mode: .used, now: Date())
    XCTAssertEqual(parts.map(\.accountName), ["C", "A"])
    XCTAssertEqual(
      draft.document.accounts.map(\.id), [accounts[2].id, accounts[0].id, accounts[1].id])
  }

  func testAddAndDeleteNormalizeOrderAndKeepExistingAccountData() {
    let first = account("A", order: 5)
    let second = account("B", order: 20)
    var draft = SettingsDraft(AccountDocument(accounts: [second, first]))

    draft.add(.openai)

    XCTAssertEqual(draft.document.accounts.map(\.order), [0, 1, 2])
    let added = draft.document.accounts[2]
    XCTAssertEqual(added.provider, .openai)
    XCTAssertEqual(added.name, "")
    XCTAssertEqual(added.configDir, "~/.codex")
    XCTAssertFalse([first.id, second.id].contains(added.id))
    draft.remove(first.id)
    XCTAssertEqual(draft.document.accounts.map(\.id), [second.id, added.id])
    XCTAssertEqual(draft.document.accounts.map(\.order), [0, 1])
    XCTAssertEqual(draft.document.accounts[0].identityFingerprint, second.identityFingerprint)
    XCTAssertEqual(draft.document.accounts[0].showInIcon, second.showInIcon)
    draft.remove(second.id)
    draft.remove(added.id)
    draft.add(.anthropic)
    XCTAssertEqual(draft.document.accounts.map(\.order), [0])
    XCTAssertEqual(draft.document.accounts[0].name, "")
    XCTAssertEqual(draft.document.accounts[0].configDir, "~/.claude")
  }

  func testDiscardedDraftLeavesOriginalDocumentUnchanged() {
    let accounts = [account("A", order: 3), account("B", order: 7)]
    var settings = Settings()
    settings.claudeSource = .statuslineOnly
    settings.codexPath = "/original/codex"
    settings.timeFormat = .hour24
    let original = AccountDocument(accounts: accounts, settings: settings)
    var draft = SettingsDraft(original)

    XCTAssertTrue(draft.move(accounts[0].id, relativeTo: accounts[1].id, after: true))
    draft.document.accounts[0].name = "Edited"
    draft.document.accounts[0].configDir = "/edited"
    draft.document.settings.claudeSource = .oauthWithStatusline
    draft.document.settings.timeFormat = .hour12
    draft.remove(accounts[0].id)
    draft.add(.openai)

    XCTAssertEqual(original.accounts, accounts)
    XCTAssertEqual(original.settings, settings)
    XCTAssertNotEqual(draft.document, original)
  }

  func testValidationRequiresOnlyConfigurationDirectory() {
    var draft = SettingsDraft(AccountDocument())
    XCTAssertFalse(draft.hasMissingDirectory)
    draft.add(.anthropic)
    XCTAssertFalse(draft.hasMissingDirectory)
    draft.document.accounts[0].name = " \n"
    XCTAssertFalse(draft.hasMissingDirectory)
    draft.document.accounts[0].configDir = ""
    XCTAssertTrue(draft.hasMissingDirectory)
    draft.document.accounts[0].configDir = "\t"
    XCTAssertTrue(draft.hasMissingDirectory)
    draft.document.accounts[0].configDir = "~/.claude"
    XCTAssertFalse(draft.hasMissingDirectory)
  }

  func testApplicableDocumentKeepsLastDirectoryAndSkipsNewAccountsWithoutOne() {
    let accounts = [account("A", order: 0), account("B", order: 1)]
    var settings = Settings()
    settings.theme = .light
    let current = AccountDocument(accounts: accounts, settings: settings)
    var draft = SettingsDraft(current)
    XCTAssertEqual(draft.applicableDocument(current: current), draft.document)

    draft.add(.openai)
    draft.document.accounts[0].configDir = " "
    draft.document.accounts[0].name = "Renamed"
    draft.document.accounts[2].configDir = ""
    draft.document.settings.theme = .dark
    let applied = draft.applicableDocument(current: current)
    XCTAssertEqual(applied.accounts.map(\.id), accounts.map(\.id))
    XCTAssertEqual(applied.accounts.map(\.configDir), accounts.map(\.configDir))
    XCTAssertEqual(applied.accounts[0].name, "Renamed")
    XCTAssertEqual(applied.accounts.map(\.order), [0, 1])
    XCTAssertEqual(applied.settings.theme, .dark)

    draft.move(accounts[1].id, to: 0)
    XCTAssertEqual(
      draft.applicableDocument(current: current).accounts.map(\.order), [0, 1],
      "Orders stay contiguous when a later account is skipped")
  }

  func testOptionalLabelsPersistThroughAccountStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AccountStore(directory: directory)
    var draft = SettingsDraft(AccountDocument())
    draft.add(.anthropic)
    draft.add(.openai)
    draft.add(.anthropic)
    draft.document.accounts[1].name = " \n\t"
    draft.document.accounts[2].name = "  Work  "

    XCTAssertFalse(draft.hasMissingDirectory)
    try store.save(draft.document)
    let loaded = try store.load()

    XCTAssertEqual(loaded, draft.document)
    XCTAssertEqual(loaded.accounts.map(\.name), ["", " \n\t", "  Work  "])
    XCTAssertEqual(loaded.accounts.map(\.displayLabel), [nil, nil, "Work"])
  }

  func testInitializationNormalizesLegacyProviderNamesOnlyInDraft() {
    let accounts = [
      Account(name: " cLaUdE \n", provider: .anthropic, configDir: "~/.claude", order: 0),
      Account(name: "CODEX", provider: .openai, configDir: "~/.codex", order: 1),
      Account(name: " \n\t", provider: .anthropic, configDir: "~/.claude-other", order: 2),
      Account(name: "  Work  ", provider: .openai, configDir: "~/.codex-work", order: 3),
    ]
    let original = AccountDocument(accounts: accounts)

    let draft = SettingsDraft(original)

    XCTAssertEqual(draft.document.accounts.map(\.name), ["", "", "", "  Work  "])
    XCTAssertEqual(draft.document.accounts.map(\.id), accounts.map(\.id))
    XCTAssertEqual(original.accounts, accounts)
    for index in accounts.indices {
      var expected = accounts[index]
      expected.name = draft.document.accounts[index].name
      XCTAssertEqual(draft.document.accounts[index], expected)
    }
  }

  func testDiscardingOptionalLabelEditsPreservesOriginalDocument() {
    let accounts = [
      Account(name: "Claude", provider: .anthropic, configDir: "~/.claude"),
      Account(name: "Work", provider: .openai, configDir: "~/.codex"),
    ]
    let original = AccountDocument(accounts: accounts)
    var draft = SettingsDraft(original)
    draft.document.accounts[0].name = "Personal"
    draft.document.accounts[1].name = ""

    XCTAssertEqual(original, AccountDocument(accounts: accounts))
    let reopened = SettingsDraft(original)
    XCTAssertEqual(reopened.document.accounts.map(\.name), ["", "Work"])
    XCTAssertEqual(reopened.document.accounts.map(\.id), accounts.map(\.id))
  }
}
