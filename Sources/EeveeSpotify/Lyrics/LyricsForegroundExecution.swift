import Foundation
#if canImport(UIKit)
import UIKit
import Network
#endif

/// Only admission of new requests depends on activity. Existing requests
/// keep their own lifetime and may finish as long as iOS lets them run.
final class LyricsForegroundExecution {
    private let condition = NSCondition()
    private var active = true
    private var hasNetworkPath = true
    private var retryAfter: Date?
    #if canImport(UIKit)
    private let pathMonitor = NWPathMonitor()
    #endif
    private var observers: [NSObjectProtocol] = []
    var enteredBackground: (() -> Void)?
    var networkLost: (() -> Void)?
    var activityChanged: ((Bool) -> Void)?

    func observe() {
        #if canImport(UIKit)
        guard observers.isEmpty else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.setNetworkAvailable(path.status != .unsatisfied)
        }
        pathMonitor.start(queue: DispatchQueue(label: "EeveeSpotify.lyrics.network"))
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.willResignActive()
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.didEnterBackground()
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.didBecomeActive()
            }
        ]
        if UIApplication.shared.applicationState != .active { willResignActive() }
        #endif
    }

    deinit {
        #if canImport(UIKit)
        pathMonitor.cancel()
        #endif
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func willResignActive() { setActive(false) }

    func didEnterBackground() {
        willResignActive()
        enteredBackground?()
    }

    func didBecomeActive() { setActive(true) }

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
