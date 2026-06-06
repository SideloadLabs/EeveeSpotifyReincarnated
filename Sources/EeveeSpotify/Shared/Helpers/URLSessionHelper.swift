import UIKit

class URLSessionHelper {
    static let shared = URLSessionHelper()

    /// Accessed from URLSession delegate callbacks which may be concurrent.
    /// Keep all mutations synchronized to avoid races / EXC_BAD_ACCESS.
    private let lock = NSLock()

    /// Keyed by the task object itself (weakly held). Previous versions used
    /// `[ObjectIdentifier: Data]` which is unsafe: a task's `ObjectIdentifier`
    /// is just its address, so once the task is deallocated the address can be
    /// reused for a brand new task — the stale buffer would then be handed to
    /// the wrong task (data corruption) and the stale `ObjectIdentifier` could
    /// even point into freed memory, crashing the URLSession delegate callback
    /// thread with the "use-after-free in didCompleteWithError" signature.
    ///
    /// `NSMapTable(strongMemory -> ...)` is not what we want because it would
    /// retain the task and prevent it from being deallocated. `weakToStrong`
    /// drops the entry automatically as soon as the task is gone, which is
    /// exactly the lifetime guarantee the previous design was trying (and
    /// failing) to express.
    private var requestsMap: NSMapTable<URLSessionTask, NSData>

    private init() {
        self.requestsMap = NSMapTable.weakToStrongObjects()
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
        let chunk = data as NSData
        lock.lock(); defer { lock.unlock() }
        if let existing = requestsMap.object(forKey: task) {
            let mutable = NSMutableData(data: existing as Data)
            mutable.append(chunk as Data)
            requestsMap.setObject(mutable as NSData, forKey: task)
        } else {
            let mutable = NSMutableData(data: chunk as Data)
            requestsMap.setObject(mutable as NSData, forKey: task)
        }
    }

    /// Returns the buffered body and removes the entry in one step. Call from
    /// `URLSession(_:task:didCompleteWithError:)` once you have decided to
    /// consume the buffer (patched, replayed, or about to fall back to the
    /// original payload).
    func obtainData(for task: URLSessionTask) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = requestsMap.object(forKey: task) else { return nil }
        requestsMap.removeObject(forKey: task)
        return raw as Data
    }

    /// Drop any buffered body for a task without consuming it. Use when a task
    /// completes via a path that won't read the buffer (cancel, blocked, 304
    /// fallback, error path) to prevent unbounded growth on long sessions.
    /// Safe to call on a task that was never buffered — no-op in that case.
    func discardData(for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        requestsMap.removeObject(forKey: task)
    }
}
