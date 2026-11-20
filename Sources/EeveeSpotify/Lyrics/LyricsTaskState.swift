import Foundation
import ObjectiveC

/// One provider answer per Spotify URLSessionTask. Both of Spotify's delegates
/// and the response and completion callbacks ask for the same task; the first
/// caller fetches, the others wait for and reuse its result. The state expires
/// with the task, so another task for the same URL fetches again.
final class LyricsTaskState {
    private static var associationKey: UInt8 = 0
    private static let associationLock = NSLock()
    static func forTask(_ task: URLSessionTask) -> LyricsTaskState {
        associationLock.lock(); defer { associationLock.unlock() }
        if let state = objc_getAssociatedObject(task, &associationKey) as? LyricsTaskState { return state }
        let state = LyricsTaskState()
        objc_setAssociatedObject(task, &associationKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
    private let lock = NSLock()
    private var stored: Result<Data, Error>?
    func result(_ fetch: () throws -> Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let stored { return try stored.get() }
        let result = Result { try fetch() }
        stored = result
        return try result.get()
    }
}
