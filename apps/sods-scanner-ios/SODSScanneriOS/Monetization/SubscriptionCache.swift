import Foundation

struct SubscriptionCachePayload: Codable, Sendable {
    var lastVerifiedAt: Date
    var expiresAt: Date?
}

final class SubscriptionCache {
    static let shared = SubscriptionCache()

    private let defaults: UserDefaults
    private let key = "SODSScanneriOS.subscription.cache"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SubscriptionCachePayload? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(SubscriptionCachePayload.self, from: data)
    }

    func save(_ payload: SubscriptionCachePayload) {
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
