import Foundation

public actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        self.value = max(0, value)
    }

    public func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func signal() {
        if waiters.isEmpty {
            value += 1
            return
        }
        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}
