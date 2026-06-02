import Foundation

struct SponsorBlockLocalSegment: Codable, Equatable, Identifiable {
    var id: String          // local UUID, also used as segment uuid prefixed "local:"
    var episodeID: String
    var start: Double
    var end: Double
    var category: String
    var createdAt: Date

    var asSegment: SponsorBlockSegment {
        SponsorBlockSegment(
            start: start,
            end: end,
            category: category,
            actionType: "skip",
            uuid: SponsorBlockLocalSegment.uuidPrefix + id,
            videoDuration: 0
        )
    }

    static let uuidPrefix = "local:"

    static func isLocalUUID(_ uuid: String) -> Bool {
        uuid.hasPrefix(uuidPrefix)
    }
}

enum SponsorBlockMySubmissionsStore {
    private static let key = "sponsorBlockMySubmissions"
    private static let lock = NSLock()
    static let changedNotification = Notification.Name("EeveeSponsorBlockMySubmissionsChanged")

    static func all() -> [String: [SponsorBlockLocalSegment]] {
        lock.lock(); defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [SponsorBlockLocalSegment]].self, from: data)
        else { return [:] }
        return decoded
    }

    static func segments(for episodeID: String) -> [SponsorBlockLocalSegment] {
        all()[episodeID] ?? []
    }

    static func add(_ seg: SponsorBlockLocalSegment) {
        var dict = all()
        var list = dict[seg.episodeID] ?? []
        list.append(seg)
        dict[seg.episodeID] = list
        save(dict)
    }

    static func remove(id: String, episodeID: String) {
        var dict = all()
        guard var list = dict[episodeID] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty { dict.removeValue(forKey: episodeID) }
        else { dict[episodeID] = list }
        save(dict)
    }

    static func clear() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static var totalCount: Int {
        all().values.reduce(0) { $0 + $1.count }
    }

    private static func save(_ dict: [String: [SponsorBlockLocalSegment]]) {
        lock.lock()
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
