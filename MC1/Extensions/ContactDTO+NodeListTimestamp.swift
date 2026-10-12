import Foundation
import MC1Services

extension ContactDTO {
  private static let nodeListMinimumAdvertTimestamp: UInt32 = 1_577_836_800
  private static let nodeListFutureTolerance: TimeInterval = 5 * 60
  private static let nodeListNeverHeardTimestamp: UInt32 = 0

  func nodeListTimestamp(relativeTo referenceDate: Date) -> UInt32? {
    let upperBound = referenceDate.timeIntervalSince1970 + Self.nodeListFutureTolerance
    if lastAdvertTimestamp >= Self.nodeListMinimumAdvertTimestamp,
       TimeInterval(lastAdvertTimestamp) <= upperBound {
      return lastAdvertTimestamp
    }

    guard let lastHeardTimestamp, lastHeardTimestamp > Self.nodeListNeverHeardTimestamp else {
      return nil
    }
    return lastHeardTimestamp
  }
}
