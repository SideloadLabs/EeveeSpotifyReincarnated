import Foundation

enum FlagKind: String, Codable {
    case bool, int, choice
}

struct FlagInfo: Codable, Identifiable, Hashable {
    let key: String
    let kind: FlagKind
    let value: String
    var lower: Int?
    var upper: Int?
    var options: [String]?

    var id: String { key }

    var component: Substring {
        key.firstIndex(of: ".").map { key[..<$0] } ?? ""
    }

    var property: Substring {
        key.firstIndex(of: ".").map { key[key.index(after: $0)...] } ?? Substring(key)
    }
}

private struct FlagCatalog: Codable {
    let spotifyVersion: String
    let flags: [FlagInfo]
}

final class RemoteFlags {
    static let shared = RemoteFlags()

    private static let overridesKey = "eeveeFlagOverrides"
    private static let catalogVersionKey = "eeveeFlagCatalogVersion"
    private static let captureKey = "eeveeFlagCapture"

    let spotifyVersion = EeveeSpotify.spotifyVersion

    private(set) var forced: [String: Any] = [:]
    private var effective: [String: Any] = [:]

    private let lock = NSLock()
    private var seen: [String: FlagInfo] = [:]
    private var applied = 0
    private var hookTicks: UInt64 = 0
    private var reads = 0
    private var flushScheduled = false
    private var cataloguing = true

    private lazy var catalogURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EeveeSpotify", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("flags.json")
    }()

    // MARK: Settings side

    static var overrides: [String: Any] {
        get { UserDefaults.standard.dictionary(forKey: overridesKey) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: overridesKey) }
    }

    static let launchOverrides = overrides as NSDictionary

    static var needsRestart: Bool { overrides as NSDictionary != launchOverrides }

    static func requestCapture() {
        UserDefaults.standard.set(true, forKey: captureKey)
    }

    var catalogIsCurrent: Bool {
        UserDefaults.standard.string(forKey: Self.catalogVersionKey) == spotifyVersion
    }

    func loadCatalog() -> [FlagInfo] {
        guard let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONDecoder().decode(FlagCatalog.self, from: data) else { return [] }
        return catalog.flags
    }

    var catalogFileURL: URL { catalogURL }

    // MARK: Launch side

    func force(_ flags: [String: Any], by owner: String) {
        forced.merge(flags) { _, new in new }
        eeveeLog("[EeveeSpotify][Flags] %@ forces %d flags", owner, flags.count)
    }

    var needsHooks: Bool {
        !forced.isEmpty
            || !Self.overrides.isEmpty
            || !catalogIsCurrent
            || UserDefaults.standard.bool(forKey: Self.captureKey)
    }

    func prepare() {
        effective = Self.overrides.merging(forced) { _, forced in forced }
        cataloguing = !catalogIsCurrent || UserDefaults.standard.bool(forKey: Self.captureKey)
        UserDefaults.standard.removeObject(forKey: Self.captureKey)
    }

    // MARK: Hot path

    func resolve(
        _ key: String,
        kind: FlagKind,
        orig: Any,
        lower: Int? = nil,
        upper: Int? = nil,
        options: @autoclosure () -> [String]? = nil,
        since start: UInt64
    ) -> Any? {
        let value = effective[key]
        lock.lock()
        reads += 1
        if value != nil { applied += 1 }
        if cataloguing, seen[key] == nil {
            seen[key] = FlagInfo(key: key, kind: kind, value: "\(orig)", lower: lower, upper: upper, options: options())
            scheduleFlush()
        } else if !cataloguing, reads == 1 {
            scheduleFlush()
        }
        hookTicks &+= mach_absolute_time() &- start
        lock.unlock()
        return value
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { self.flush() }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        let (fresh, reads, applied, ticks) = (seen, reads, applied, hookTicks)
        lock.unlock()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ms = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        guard cataloguing else {
            eeveeLog("[EeveeSpotify][Flags] %d reads, %d overridden, hook cost %.2f ms", reads, applied, ms)
            return
        }

        var merged = catalogIsCurrent ? Dictionary(loadCatalog().map { ($0.key, $0) }) { a, _ in a } : [:]
        merged.merge(fresh) { _, new in new }
        let catalog = FlagCatalog(spotifyVersion: spotifyVersion, flags: merged.values.sorted { $0.key < $1.key })
        do {
            try JSONEncoder().encode(catalog).write(to: catalogURL, options: .atomic)
            UserDefaults.standard.set(spotifyVersion, forKey: Self.catalogVersionKey)
        } catch {
            eeveeLog("[EeveeSpotify][Flags] Catalog write failed: %@", "\(error)")
        }
        eeveeLog("[EeveeSpotify][Flags] %d reads, %d seen, %d catalogued, %d overridden, hook cost %.2f ms", reads, fresh.count, catalog.flags.count, applied, ms)
    }
}
