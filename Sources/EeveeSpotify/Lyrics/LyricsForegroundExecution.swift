import Foundation
#if canImport(UIKit)
import UIKit
import Network
#endif

/// Admission of new lyrics requests. They run while Spotify is on screen and during the
/// short time iOS grants after it is minimized; when that ends, only while Spotify keeps
/// playing, since iOS keeps a playing app running. Otherwise new requests wait for the
/// screen. Existing requests keep their own lifetime and may finish as long as iOS lets them run.
final class LyricsForegroundExecution {
    private let condition = NSCondition()
    private var active = true
    private var hasNetworkPath = true
    private var retryAfter: Date?
    #if canImport(UIKit)
    private let pathMonitor = NWPathMonitor()
    /// The minimized time iOS granted, held only while there is lyrics work.
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif
    private var observers: [NSObjectProtocol] = []
    var enteredBackground: (() -> Void)?
    var networkLost: (() -> Void)?
    var activityChanged: ((Bool) -> Void)?
    /// Whether there is lyrics work to ask iOS for minimized time (main thread).
    var hasWork: () -> Bool = { false }
    /// Whether Spotify is playing, read when the minimized time ends.
    var isPlaying: () -> Bool = { false }
    /// Called when the minimized time ends; true when playback keeps the queue running.
    var backgroundTimeEnded: ((Bool) -> Void)?

    func observe() {
        #if canImport(UIKit)
        guard observers.isEmpty else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.setNetworkAvailable(path.status != .unsatisfied)
        }
        pathMonitor.start(queue: DispatchQueue(label: "EeveeSpotify.lyrics.network"))
        let center = NotificationCenter.default
        // Only leaving the screen matters: an inactive app (Control Center, a call banner)
        // is still on screen and keeps its queue.
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.didEnterBackground()
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.didBecomeActive()
            }
        ]
        // Launched in the background by iOS: no minimized time is asked for.
        if UIApplication.shared.applicationState == .background { endBackgroundTime() }
        #endif
    }

    deinit {
        #if canImport(UIKit)
        pathMonitor.cancel()
        #endif
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func didEnterBackground() {
        enteredBackground?()
        #if canImport(UIKit)
        if backgroundTask == .invalid, hasWork() {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "EeveeSpotify lyrics") { [weak self] in
                self?.endBackgroundTime()
            }
        }
        if backgroundTask != .invalid { return }
        #endif
        endBackgroundTime()
    }

    /// The minimized time ended, was not granted, or was not needed.
    func endBackgroundTime() {
        releaseBackgroundTask()
        let playing = isPlaying()
        if !playing { setActive(false) }
        backgroundTimeEnded?(playing)
    }

    /// The queue has nothing left: give the minimized time back to iOS early.
    func workFinished() { releaseBackgroundTask() }

    func didBecomeActive() {
        releaseBackgroundTask()
        setActive(true)
    }

    private func releaseBackgroundTask() {
        #if canImport(UIKit)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }

    private func setActive(_ next: Bool) {
        condition.lock()
        guard active != next else { condition.unlock(); return }
        active = next
        if next { condition.broadcast() }
        condition.unlock()
        activityChanged?(next)
    }

    var isActive: Bool {
        condition.lock(); defer { condition.unlock() }
        return active
    }

    func whenActive(isCancelled: () -> Bool, _ start: () -> Void = {}) throws {
        condition.lock()
        defer { condition.unlock() }
        while !active && !isCancelled() { condition.wait() }
        guard !isCancelled() else { throw URLError(.cancelled) }
        start()
    }

    func setNetworkAvailable(_ available: Bool) {
        condition.lock()
        let lost = hasNetworkPath && !available
        if available && !hasNetworkPath { retryAfter = nil }
        hasNetworkPath = available
        condition.broadcast()
        condition.unlock()
        if lost { networkLost?() }
    }

    // A route may exist even when URLSession reports -1009. Keep the job
    // pending and allow a later probe if the route never changes.
    func connectionFailed() {
        condition.lock()
        let lost = hasNetworkPath && (retryAfter ?? .distantPast) <= Date()
        retryAfter = Date(timeIntervalSinceNow: 30)
        condition.broadcast()
        condition.unlock()
        if lost { networkLost?() }
    }

    /// No network route at all, unlike `networkUnavailable`, which also covers a recent failed request.
    var isOffline: Bool {
        condition.lock(); defer { condition.unlock() }
        return !hasNetworkPath
    }

    var networkUnavailable: Bool {
        condition.lock(); defer { condition.unlock() }
        return !hasNetworkPath || (retryAfter ?? .distantPast) > Date()
    }

    func whenNetworkAvailable(isCancelled: () -> Bool, _ start: () -> Void = {}) throws {
        condition.lock(); defer { condition.unlock() }
        while !isCancelled() {
            if !active || !hasNetworkPath { condition.wait(); continue }
            if let deadline = retryAfter, deadline > Date() {
                condition.wait(until: deadline)
                continue
            }
            start()
            return
        }
        throw URLError(.cancelled)
    }

    func recheckWaitingRequests() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}
