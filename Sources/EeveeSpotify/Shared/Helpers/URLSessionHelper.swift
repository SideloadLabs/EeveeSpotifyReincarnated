import UIKit

class URLSessionHelper {
    static let shared = URLSessionHelper()

    /// Accessed from URLSession delegate callbacks which may be concurrent.
    /// Keep all mutations synchronized to avoid races / EXC_BAD_ACCESS.
    private let queue = DispatchQueue(label: "com.eeveespotify.urlsessionhelper.requestsMap")

    /// Keyed by the task object's identity, not its URL. Two concurrent tasks
    /// hitting the same URL (retry / dedup race / parallel fetch) would otherwise
    /// concatenate bodies → garbage protobuf. ObjectIdentifier is stable for the
    /// task's lifetime, which exactly bounds the buffering window.
    private var requestsMap: [ObjectIdentifier: Data]

    private init() {
        self.requestsMap = [:]
    }

    static var DarwinVersion: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let dv = String(
            bytes: Data(bytes: &sysinfo.release, count: Int(_SYS_NAMELEN)),
            encoding: .ascii
        )!.trimmingCharacters(in: .controlCharacters)
        return "Darwin/\(dv)"
    }

    static var CFNetworkVersion: String {
        let dictionary = Bundle(identifier: "com.apple.CFNetwork")?.infoDictionary!
        let version = dictionary?["CFBundleShortVersionString"] as! String
        return "CFNetwork/\(version)"
    }

    func setOrAppend(_ data: Data, for task: URLSessionTask) {
        let key = ObjectIdentifier(task)
        queue.sync {
            var loadedData = requestsMap[key] ?? Data()
            loadedData.append(data)
            requestsMap[key] = loadedData
        }
    }

    func obtainData(for task: URLSessionTask) -> Data? {
        let key = ObjectIdentifier(task)
        return queue.sync {
            requestsMap.removeValue(forKey: key)
        }
    }

    /// Drop any buffered body for a task without consuming it. Use when a task
    /// completes via a path that won't read the buffer (cancel, blocked, 304
    /// fallback) to prevent unbounded growth on long sessions.
    func discardData(for task: URLSessionTask) {
        let key = ObjectIdentifier(task)
        queue.sync {
            _ = requestsMap.removeValue(forKey: key)
        }
    }
}
