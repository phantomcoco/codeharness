import CryptoKit
import Foundation

public struct CommandPolicy: Equatable, Sendable {
    public let id: String
    public let executableURL: URL
    public let arguments: [String]
    public static let swiftTest = CommandPolicy(
        id: "swift-test",
        executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
        arguments: ["test"]
    )
}
