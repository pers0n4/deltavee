import DeltaveeCore
import Foundation

struct SettingsDraft {
  var document: AccountDocument

  init(_ document: AccountDocument) {
    self.document = document
    self.document.accounts = document.accounts.enumerated().sorted {
      if $0.element.order == $1.element.order { return $0.offset < $1.offset }
      return $0.element.order < $1.element.order
    }.map {
      var account = $0.element
      if account.displayLabel == nil { account.name = "" }
      return account
    }
  }

  func canMoveUp(_ id: UUID) -> Bool {
    guard let index = document.accounts.firstIndex(where: { $0.id == id }) else { return false }
    return index > 0
  }

  func canMoveDown(_ id: UUID) -> Bool {
    guard let index = document.accounts.firstIndex(where: { $0.id == id }) else { return false }
    return index + 1 < document.accounts.count
  }

  mutating func moveUp(_ id: UUID) {
    guard canMoveUp(id), let index = document.accounts.firstIndex(where: { $0.id == id }) else {
      return
    }
    move(id, relativeTo: document.accounts[index - 1].id, after: false)
  }

  mutating func moveDown(_ id: UUID) {
    guard canMoveDown(id), let index = document.accounts.firstIndex(where: { $0.id == id }) else {
      return
    }
    move(id, relativeTo: document.accounts[index + 1].id, after: true)
  }

  @discardableResult
  mutating func move(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
    guard id != target,
      let source = document.accounts.firstIndex(where: { $0.id == id }),
      let targetIndex = document.accounts.firstIndex(where: { $0.id == target })
    else { return false }
    let insertion = targetIndex + (after ? 1 : 0)
    let destination = source < insertion ? insertion - 1 : insertion
    guard source != destination else { return false }
    let account = document.accounts.remove(at: source)
    document.accounts.insert(account, at: destination)
    normalizeOrder()
    return true
  }

  /// Moves an account to `destination`, its index after the move.
  @discardableResult
  mutating func move(_ id: UUID, to destination: Int) -> Bool {
    guard let source = document.accounts.firstIndex(where: { $0.id == id }),
      document.accounts.indices.contains(destination), source != destination
    else { return false }
    let account = document.accounts.remove(at: source)
    document.accounts.insert(account, at: destination)
    normalizeOrder()
    return true
  }

  mutating func add(_ provider: Provider) {
    document.accounts.append(
      Account(
        name: "", provider: provider,
        configDir: provider == .anthropic ? "~/.claude" : "~/.codex"))
    normalizeOrder()
  }

  mutating func remove(_ id: UUID) {
    guard let index = document.accounts.firstIndex(where: { $0.id == id }) else { return }
    document.accounts.remove(at: index)
    normalizeOrder()
  }

  private mutating func normalizeOrder() {
    for index in document.accounts.indices { document.accounts[index].order = index }
  }

  var hasMissingDirectory: Bool {
    document.accounts.contains {
      $0.configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// The document to apply live. An account without a configuration directory keeps its last
  /// applied directory, and a new account is not applied until it has one.
  func applicableDocument(current: AccountDocument) -> AccountDocument {
    var result = document
    result.accounts = document.accounts.compactMap { account in
      guard account.configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return account
      }
      guard let applied = current.accounts.first(where: { $0.id == account.id }) else { return nil }
      var kept = account
      kept.configDir = applied.configDir
      return kept
    }
    for index in result.accounts.indices { result.accounts[index].order = index }
    return result
  }
}
