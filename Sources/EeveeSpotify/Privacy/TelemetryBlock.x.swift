import Foundation
import Orion

// Spotify's own gabo-receiver-service events stay untouched: Recents is built from them.
struct TelemetryBlockGroup: HookGroup {}

enum TelemetryBlock {
    static let launchEnabled = UserDefaults.blockTelemetry

    private static let rules: [(host: String, dotted: String, path: String?, label: String)] = ([
        ("app-measurement.com", nil, "Firebase"),
        ("firebaselogging-pa.googleapis.com", nil, "Firebase"),
        ("crashlytics.com", nil, "Crashlytics"),
        ("facebook.com", "/activities", "Facebook"),
        ("ep1.facebook.com", nil, "Facebook"),
        ("ep2.facebook.com", nil, "Facebook"),
        ("branch.io", "/v1/event", "Branch"),
        ("scorecardresearch.com", nil, "Comscore"),
        ("segment.io", nil, "Segment"),
        ("zqtk.net", nil, "Segment"),
        ("google-analytics.com", nil, "Google"),
        ("googleadservices.com", nil, "Google"),
        ("doubleclick.net", nil, "Google"),
    ] as [(String, String?, String)]).map { ($0.0, "." + $0.0, $0.1, $0.2) }

    private static let lock = NSLock()
    private static var counts = [String: Int]()
    private static var total = 0

    static func label(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        let path = url?.path ?? ""
        return rules.first { rule in
            (host == rule.host || host.hasSuffix(rule.dotted)) && (rule.path.map(path.contains) ?? true)
        }?.label
    }

    static func record(_ label: String, _ url: URL) {
        lock.lock()
        counts[label, default: 0] += 1
        let first = counts[label] == 1
        total += 1
        let summary = total % 25 == 0 ? counts.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ") : nil
        lock.unlock()
        if first { eeveeLog("[EeveeSpotify][Privacy] Blocked %@ %@%@", label, url.host ?? "", url.path) }
        if let summary { eeveeLog("[EeveeSpotify][Privacy] %d blocked: %@", total, summary) }
    }

    static func install(into configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        var classes = configuration.protocolClasses ?? []
        guard !classes.contains(where: { $0 == TelemetryBlockProtocol.self }) else { return configuration }
        classes.insert(TelemetryBlockProtocol.self, at: 0)
        configuration.protocolClasses = classes
        return configuration
    }
}

final class TelemetryBlockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        TelemetryBlock.label(for: request.url) != nil
    }

    private lazy var label = TelemetryBlock.label(for: request.url)

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        label.map { TelemetryBlock.record($0, url) }
        guard let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// URLProtocol.registerClass only reaches the shared session; SDKs build theirs from these configurations.
class SessionConfigurationHook: ClassHook<URLSessionConfiguration> {
    typealias Group = TelemetryBlockGroup

    class func defaultSessionConfiguration() -> URLSessionConfiguration {
        TelemetryBlock.install(into: orig.defaultSessionConfiguration())
    }

    class func ephemeralSessionConfiguration() -> URLSessionConfiguration {
        TelemetryBlock.install(into: orig.ephemeralSessionConfiguration())
    }
}

extension UserDefaults {
    static var blockTelemetry: Bool {
        get { container.object(forKey: "eeveeBlockTelemetry") as? Bool ?? true }
        set { container.set(newValue, forKey: "eeveeBlockTelemetry") }
    }
}

func activateTelemetryBlock() {
    guard TelemetryBlock.launchEnabled else { return }
    let start = CFAbsoluteTimeGetCurrent()
    URLProtocol.registerClass(TelemetryBlockProtocol.self)
    TelemetryBlockGroup().activate()
    eeveeLog("[EeveeSpotify][Privacy] Telemetry block on (%.2f ms)", (CFAbsoluteTimeGetCurrent() - start) * 1000)
}
