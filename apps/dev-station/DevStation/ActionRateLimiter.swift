import Foundation

@MainActor
final class ActionRateLimiter: ObservableObject {
    static let shared = ActionRateLimiter()

    private var lastFire: [String: Date] = [:]

    private init() {}

    func canFire(key: String, cooldownSeconds: TimeInterval) -> (ok: Bool, remaining: TimeInterval) {
        let now = Date()
        if let last = lastFire[key] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < cooldownSeconds {
                return (false, cooldownSeconds - elapsed)
            }
        }
        return (true, 0)
    }

    func markFired(key: String) {
        lastFire[key] = Date()
    }
}

