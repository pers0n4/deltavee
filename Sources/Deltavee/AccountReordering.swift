import Foundation
import SwiftUI

/// In-panel card reordering: the dragged card follows the pointer while the others slide aside.
/// Layout math is kept pure so the drop index and the card shifts are testable without a view.
enum AccountReordering {
  /// Index the dragged card occupies once it is removed and reinserted, chosen by comparing the
  /// dragged card's center against the resting centers of the other cards.
  static func destination(
    heights: [CGFloat], source: Int, translation: CGFloat, spacing: CGFloat
  ) -> Int {
    guard heights.indices.contains(source), translation.isFinite else { return source }
    var top: CGFloat = 0
    var centers: [CGFloat] = []
    for height in heights {
      centers.append(top + height / 2)
      top += height + spacing
    }
    let center = centers[source] + translation
    return heights.indices.filter { $0 != source && centers[$0] < center }.count
  }

  /// Vertical shift for a resting card so the slot at `destination` opens for the dragged card.
  static func offset(index: Int, source: Int, destination: Int, shift: CGFloat) -> CGFloat {
    if index > source && index <= destination { return -shift }
    if index < source && index >= destination { return shift }
    return 0
  }
}

struct AccountCardDrag: Equatable {
  let id: UUID
  let source: Int
  var translation: CGFloat
}

struct AccountCardHeightsKey: PreferenceKey {
  static let defaultValue: [UUID: CGFloat] = [:]
  static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
