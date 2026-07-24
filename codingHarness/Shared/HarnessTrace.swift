import CryptoKit
import Foundation

public enum HarnessTrace {
    #if DEBUG
    public static var isEnabled = true

    public static func log(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard isEnabled else { return }
        print("[HarnessTrace] \(file):\(line) \(message())")
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
