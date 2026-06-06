import Foundation

// Pre-fetches custom lyrics during `didReceiveResponse` so that
// `didCompleteWithError` can forward the response synchronously without
// blocking the URLSession delegate thread on a semaphore.
//
// The previous implementation used a 5-second `semaphore.wait` inside
// `didCompleteWithError`. Blocking a URLSession delegate callback for that
// long is a known anti-pattern: the URLSession system can decide to
// invalidate the task/connection while we are still inside the call, which
// races with the subsequent `orig.URLSession(...)` invocations and was the
// direct trigger for the "EXC_BAD_ACCESS in didCompleteWithError" crash.
//
// We use a weak-keyed `NSMapTable` so a task that is deallocated before the
// pre-fetch finishes drops its entry automatically — no manual cleanup, no
// dangling pointers.
enum LyricsPrefetch {

    private static let lock = NSLock()
    private static var pending: NSMapTable<URLSessionTask, NSData> =
        NSMapTable.weakToStrongObjects()

    /// Begin an async custom-lyrics fetch for the given task. Safe to call
    /// multiple times for the same task — a second call is a no-op while a
    /// fetch is already pending.
    static func start(task: URLSessionTask, path: String) {
        lock.lock()
        if pending.object(forKey: task) != nil {
            lock.unlock()
            return
        }
        // Reserve the slot with an empty NSData so a concurrent `pop` knows
        // a fetch is in flight and waits for the result.
        pending.setObject(NSData(), forKey: task)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? getLyricsDataForCurrentTrack(path)) ?? nil
            let boxed = (data as NSData?) ?? NSData()
            lock.lock()
            pending.setObject(boxed, forKey: task)
            lock.unlock()
        }
    }

    /// Returns the pre-fetched body if it is ready, otherwise `nil`. The
    /// entry is removed in either case so the map cannot grow unbounded.
    ///
    /// Callers must always pass the result through (or fall back to the
    /// original buffer) — never return early on `nil`, otherwise the
    /// consumer sees a missing didReceiveData and the URLSession system
    /// reports a task-level error.
    static func pop(_ task: URLSessionTask) -> Data? {
        lock.lock()
        let raw = pending.object(forKey: task)
        pending.removeObject(forKey: task)
        lock.unlock()
        guard let raw, raw.length > 0 else { return nil }
        return raw as Data
    }
}
