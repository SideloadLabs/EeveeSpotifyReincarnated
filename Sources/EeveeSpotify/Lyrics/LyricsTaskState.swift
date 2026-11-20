import Foundation
import ObjectiveC

/// One provider result per Spotify URLSessionTask, shared by both delegates.
/// Associated storage expires with the task: another task for the same URL
/// always makes its own fresh online request.
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
    private var result: Result<Data, Error>?
    private var started = false
    private var callbacks: [(Result<Data, Error>) -> Void] = []
    private var completedDelegates = Set<String>()
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func claimCompletion(delegate: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return completedDelegates.insert(delegate).inserted
    }
    func load(_ fetch: @escaping () throws -> Data, completion: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        if let result { lock.unlock(); completion(result); return }
        callbacks.append(completion)
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try fetch() }
            self.lock.lock()
            self.result = result
            let callbacks = self.callbacks
            self.callbacks.removeAll()
            self.lock.unlock()
            for callback in callbacks { callback(result) }
        }
    }
}
