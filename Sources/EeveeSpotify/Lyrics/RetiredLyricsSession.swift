import Foundation
import EeveeSpotifyC

/// Upgrades from builds that handed lyrics tasks to iOS cancel that session.
/// New installs have no journal and never open a background session.
final class RetiredLyricsSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EeveeSpotify/LyricsTransfers", isDirectory: true)
    private static let shared = RetiredLyricsSession()
    private var session: URLSession?
    private var finished = false
    private var completions: [() -> Void] = []

    static func install() {
        guard let bundle = Bundle.main.bundleIdentifier,
              FileManager.default.fileExists(atPath: directory.path) else { return }
        let identifier = bundle + ".pixie.lyrics.http"
        EeveeInstallRetiredLyricsSessionDelegate { requested, completion in
            guard requested == identifier else { return false }
            DispatchQueue.main.async { shared.cancel(identifier, completion: completion) }
            return true
        }
        DispatchQueue.main.async { shared.cancel(identifier) }
    }

    private func cancel(_ identifier: String, completion: (() -> Void)? = nil) {
        if finished { completion?(); return }
        if let completion { completions.append(completion) }
        guard session == nil else { return }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
            session.invalidateAndCancel()
            DispatchQueue.main.async {
                writeDebugLog("[Lyrics] retired \(tasks.count) background transfer(s)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) { self.releaseCompletions() }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        finished = true
        self.session = nil
        if let error {
            writeDebugLog("[Lyrics] could not retire old background transfers: \(error.localizedDescription)")
        } else {
            do { try FileManager.default.removeItem(at: Self.directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
            catch { writeDebugLog("[Lyrics] could not remove old transfer journal: \(error.localizedDescription)") }
        }
        releaseCompletions()
    }

    private func releaseCompletions() {
        let pending = completions
        completions.removeAll()
        for completion in pending { completion() }
    }
}
