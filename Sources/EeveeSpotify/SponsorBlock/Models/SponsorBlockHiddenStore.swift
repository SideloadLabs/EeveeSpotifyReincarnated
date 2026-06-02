import Foundation

enum SponsorBlockHiddenStore {
    private static let key = "sponsorBlockHiddenSegments"
    private static let lock = NSLock()
    static let changedNotification = Notification.Name("EeveeSponsorBlockHiddenChanged")

    static func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func contains(_ uuid: String) -> Bool {
        all().contains(uuid)
    }

    static func add(_ uuid: String) {
        lock.lock()
        var set = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        set.insert(uuid)
        UserDefaults.standard.set(Array(set), forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func remove(_ uuid: String) {
        lock.lock()
        var set = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        set.remove(uuid)
        UserDefaults.standard.set(Array(set), forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func clear() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
