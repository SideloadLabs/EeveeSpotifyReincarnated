import Foundation

enum SponsorBlockVote: Int {
    case down = 0
    case up = 1
    case undo = 20
}

enum SponsorBlockVotedStore {
    private static let key = "sponsorBlockVotedSegments"
    private static let lock = NSLock()
    static let changedNotification = Notification.Name("EeveeSponsorBlockVotedChanged")

    enum Direction: String { case up, down }

    static func all() -> [String: Direction] {
        lock.lock(); defer { lock.unlock() }
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return [:] }
        return raw.compactMapValues { Direction(rawValue: $0) }
    }

    static func direction(for uuid: String) -> Direction? {
        all()[uuid]
    }

    static func record(uuid: String, vote: SponsorBlockVote) {
        lock.lock()
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        switch vote {
        case .up:   dict[uuid] = Direction.up.rawValue
        case .down: dict[uuid] = Direction.down.rawValue
        case .undo: dict.removeValue(forKey: uuid)
        }
        UserDefaults.standard.set(dict, forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func clear() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static var count: Int { all().count }
}
