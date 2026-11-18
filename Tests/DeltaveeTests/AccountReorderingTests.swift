import XCTest

@testable import Deltavee

final class AccountReorderingTests: XCTestCase {
  private let heights: [CGFloat] = [40, 80, 40, 60]
  private let spacing: CGFloat = 12

  private func destination(_ source: Int, _ translation: CGFloat) -> Int {
    AccountReordering.destination(
      heights: heights, source: source, translation: translation, spacing: spacing)
  }

  func testStaysInPlaceUntilCenterCrossesNeighborCenter() {
    // Card 0 center 20; card 1 center 92. Crossing requires translation > 72.
    XCTAssertEqual(destination(0, 0), 0)
    XCTAssertEqual(destination(0, 72), 0)
    XCTAssertEqual(destination(0, 72.5), 1)
    // Card 2 center 164; card 1 center 92. Moving up swaps once the centers meet.
    XCTAssertEqual(destination(2, -71.5), 2)
    XCTAssertEqual(destination(2, -72), 1)
  }

  func testClampsBeyondListEnds() {
    XCTAssertEqual(destination(1, -10_000), 0)
    XCTAssertEqual(destination(1, 10_000), 3)
    XCTAssertEqual(destination(3, 10_000), 3)
  }

  func testInvalidInputKeepsSource() {
    XCTAssertEqual(destination(1, .nan), 1)
    XCTAssertEqual(destination(1, .infinity), 1)
    XCTAssertEqual(
      AccountReordering.destination(heights: heights, source: 9, translation: 50, spacing: spacing),
      9)
  }

  func testRestingCardsShiftTowardVacatedSlot() {
    let shift: CGFloat = 52
    // Dragging index 0 to index 2: cards 1 and 2 move up, card 3 stays.
    XCTAssertEqual(
      (0..<4).map {
        AccountReordering.offset(index: $0, source: 0, destination: 2, shift: shift)
      }, [0, -shift, -shift, 0])
    // Dragging index 3 to index 1: cards 1 and 2 move down, card 0 stays.
    XCTAssertEqual(
      (0..<4).map {
        AccountReordering.offset(index: $0, source: 3, destination: 1, shift: shift)
      }, [0, shift, shift, 0])
    XCTAssertEqual(
      (0..<4).map {
        AccountReordering.offset(index: $0, source: 2, destination: 2, shift: shift)
      }, [0, 0, 0, 0])
  }

  func testShiftedLayoutMatchesCommittedOrder() {
    // Resting cards plus the open slot must land exactly where the committed move places them.
    for source in heights.indices {
      for target in heights.indices {
        let shift = heights[source] + spacing
        var order = Array(heights.indices)
        order.insert(order.remove(at: source), at: target)
        var top: CGFloat = 0
        var committedTops: [Int: CGFloat] = [:]
        for index in order {
          committedTops[index] = top
          top += heights[index] + spacing
        }
        var originalTop: CGFloat = 0
        for index in heights.indices {
          if index != source {
            let shifted =
              originalTop
              + AccountReordering.offset(
                index: index, source: source, destination: target, shift: shift)
            XCTAssertEqual(shifted, committedTops[index], "source \(source) target \(target)")
          }
          originalTop += heights[index] + spacing
        }
      }
    }
  }
}
