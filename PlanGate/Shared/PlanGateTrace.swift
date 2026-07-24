import CryptoKit
import Foundation

public enum PlanGateTrace {
    #if DEBUG
    public static var isEnabled = true

    public static func log(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard isEnabled else { return }
        print("[PlanGateTrace] \(file):\(line) \(message())")
    }
    #else
    public static var isEnabled = false

    public static func log(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {}
    #endif
}
