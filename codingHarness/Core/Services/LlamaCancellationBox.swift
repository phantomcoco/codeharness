#if canImport(llama)
import Foundation
import llama

final class LlamaCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func reset() {
        lock.lock()
        value = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
#endif
