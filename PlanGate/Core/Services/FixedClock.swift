import CryptoKit
import Foundation

public struct FixedClock: Clock {
    public let fixedDate: Date
    public init(_ fixedDate: Date) { self.fixedDate = fixedDate }
    public func now() -> Date { fixedDate }
}
