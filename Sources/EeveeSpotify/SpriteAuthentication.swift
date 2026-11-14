import Foundation

// Reuse headers already observed by Eevee's existing Spotify delegates.
// Values stay in memory; the manager never logs or persists credentials.
@objc(SpriteAuthentication)
final class SpriteAuthentication: NSObject {
    private static let lock = NSLock()
    private static var captured: [String: String] = [:]
    private static var capturedAt = Date.distantPast

    static func capture(_ request: URLRequest?, session: URLSession?) {
        guard let host = request?.url?.host?.lowercased(),
              host.hasSuffix(".spotify.com"), host.contains("spclient") else { return }
        let names: Set<String> = ["authorization", "client-token", "spotify-app-version", "app-platform", "user-agent"]
        var values: [String: String] = [:]
        for (key, value) in session?.configuration.httpAdditionalHeaders ?? [:] {
            guard let name = key as? String, let text = value as? String,
                  names.contains(name.lowercased()) else { continue }
            values[name.lowercased()] = text
        }
        for (name, value) in request?.allHTTPHeaderFields ?? [:] where names.contains(name.lowercased()) {
            values[name.lowercased()] = value
        }
        guard values["authorization"]?.hasPrefix("Bearer ") == true else { return }
        lock.lock()
        captured = values
        capturedAt = Date()
        lock.unlock()
    }

    @objc(headersWithCompletion:)
    static func headers(completion: @escaping (NSDictionary) -> Void) {
        lock.lock()
        let values = Date().timeIntervalSince(capturedAt) < 300 ? captured : [:]
        lock.unlock()
        completion(values as NSDictionary)
    }
}
