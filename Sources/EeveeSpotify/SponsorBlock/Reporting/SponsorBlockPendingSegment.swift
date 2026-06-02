import Foundation

struct SponsorBlockPendingSegment: Codable, Equatable, Identifiable {
    var id: UUID
    var episodeID: String
    var start: Double
    var end: Double?
    var category: String
    var actionType: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        episodeID: String,
        start: Double,
        end: Double? = nil,
        category: String = "sponsor",
        actionType: String = "skip",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.episodeID = episodeID
        self.start = start
        self.end = end
        self.category = category
        self.actionType = actionType
        self.createdAt = createdAt
    }

    var isReadyToSubmit: Bool {
        guard let end else { return false }
        return end > start
    }
}

enum SponsorBlockPendingStore {
    private static let key = "sponsorBlockPendingSegments"
    private static let lock = NSLock()
    static let changedNotification = Notification.Name("EeveeSponsorBlockPendingChanged")

    static func all() -> [String: [SponsorBlockPendingSegment]] {
        lock.lock(); defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [SponsorBlockPendingSegment]].self, from: data)
        else { return [:] }
        return decoded
    }

    static func segments(for episodeID: String) -> [SponsorBlockPendingSegment] {
        all()[episodeID] ?? []
    }

    static func upsert(_ seg: SponsorBlockPendingSegment) {
        var dict = all()
        var list = dict[seg.episodeID] ?? []
        if let idx = list.firstIndex(where: { $0.id == seg.id }) {
            list[idx] = seg
        } else {
            list.append(seg)
        }
        dict[seg.episodeID] = list
        save(dict)
    }

    static func remove(id: UUID, episodeID: String) {
        var dict = all()
        guard var list = dict[episodeID] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty { dict.removeValue(forKey: episodeID) }
        else { dict[episodeID] = list }
        save(dict)
    }

    static func clear(episodeID: String) {
        var dict = all()
        dict.removeValue(forKey: episodeID)
        save(dict)
    }

    private static func save(_ dict: [String: [SponsorBlockPendingSegment]]) {
        lock.lock()
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
