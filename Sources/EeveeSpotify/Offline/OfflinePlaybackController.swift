import AVFoundation
import MediaPlayer
import UIKit
import ObjectiveC.runtime

public final class OfflinePlaybackController: NSObject, AVAudioPlayerDelegate {
    public static let shared = OfflinePlaybackController()
    static let changed = Notification.Name("EeveeOfflinePlaybackChanged")

    private var audioPlayer: AVAudioPlayer?
    private var spotifySessionLease: NSObject?
    public private(set) var currentTrack: OfflineTrack?
    public private(set) var playlistQueue: [OfflineTrack] = []
    public private(set) var currentIndex = -1
    public private(set) var isShuffleEnabled = false
    public private(set) var isRepeatEnabled = false
    private var history: [Int] = []
    private var commandTargets: [(MPRemoteCommand, Any, Bool)] = []
    private var previousNowPlayingInfo: [String: Any]?

    public var isPlaying: Bool { audioPlayer?.isPlaying ?? false }
    public var currentTime: TimeInterval { audioPlayer?.currentTime ?? 0 }
    public var duration: TimeInterval { audioPlayer?.duration ?? 0 }

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleRouteChange),
                           name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(libraryChanged), name: OfflineLibraryStore.changed, object: nil)
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in self?.pause() }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: kind) == .began else { return }
        DispatchQueue.main.async { [weak self] in self?.pause() }
    }

    @objc private func libraryChanged() {
        guard let currentTrack else { return }
        if !OfflineLibraryStore.shared.isDownloaded(currentTrack.id) {
            if !playNext() { stop() }
        } else {
            updateNowPlayingInfo()
            OfflineGlobalPlayerOverlay.shared.updateMetadata(track: currentTrack)
        }
    }

    public func toggleShuffle() {
        isShuffleEnabled.toggle()
        history.removeAll()
        updateNowPlayingInfo()
    }

    public func toggleRepeat() {
        isRepeatEnabled.toggle()
        updateNowPlayingInfo()
    }

    @discardableResult
    public func setQueue(_ tracks: [OfflineTrack], startIndex: Int = 0) -> Bool {
        guard tracks.indices.contains(startIndex) else { return false }
        let previousQueue = playlistQueue
        let previousIndex = currentIndex
        playlistQueue = tracks
        currentIndex = startIndex
        if play(track: tracks[startIndex]) {
            history.removeAll()
            updateNowPlayingInfo()
            return true
        }
        playlistQueue = previousQueue
        currentIndex = previousIndex
        return false
    }

    public func play(track: OfflineTrack) -> Bool {
        if currentTrack?.id == track.id, audioPlayer != nil { return resume() }
        guard let file = OfflineLibraryStore.shared.localFileURL(for: track.id),
              let candidate = try? AVAudioPlayer(contentsOf: file),
              candidate.prepareToPlay() else { return false }
        OfflineSpotifyPlayback.setLocalVolumeOwner(true)
        defer {
            if currentTrack == nil { OfflineSpotifyPlayback.setLocalVolumeOwner(false) }
        }
        do {
            let wasPlaying = isPlaying
            try activateAudioSession()
            pauseSpotifyPlayer()
            audioPlayer?.pause()
            guard candidate.play() else {
                if wasPlaying { _ = audioPlayer?.play() }
                if !wasPlaying { releaseAudioSession(deactivateStandaloneSession: true) }
                return false
            }
            audioPlayer?.delegate = nil
            audioPlayer?.stop()
            audioPlayer = candidate
            candidate.delegate = self
            currentTrack = track
            if let index = playlistQueue.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            } else {
                playlistQueue = [track]
                currentIndex = 0
                history.removeAll()
            }
            attachRemoteCommands()
            updateNowPlayingInfo()
            OfflineGlobalPlayerOverlay.shared.show(track: track)
            return true
        } catch {
            return false
        }
    }

    private func nextIndices() -> [Int] {
        OfflinePlaybackOrder.next(count: playlistQueue.count, current: currentIndex, history: history, shuffle: isShuffleEnabled)
    }

    public func playNext() -> Bool {
        let previous = currentIndex
        for index in nextIndices() where play(track: playlistQueue[index]) {
            history.append(previous)
            updateNowPlayingInfo()
            return true
        }
        return false
    }

    public func playPrevious() -> Bool {
        guard currentTrack != nil else { return false }
        if currentTime > 3 { seek(to: 0); return true }
        if isShuffleEnabled {
            while let index = history.popLast() {
                if playlistQueue.indices.contains(index), play(track: playlistQueue[index]) { return true }
            }
        } else if currentIndex > 0 {
            for index in stride(from: currentIndex - 1, through: 0, by: -1) where play(track: playlistQueue[index]) {
                return true
            }
        }
        seek(to: 0)
        return true
    }

    public func pause() {
        guard let audioPlayer else { return }
        audioPlayer.pause()
        releaseAudioSession(deactivateStandaloneSession: true)
        updateNowPlayingInfo()
    }

    @discardableResult
    public func resume() -> Bool {
        guard let player = audioPlayer, let currentTrack,
              OfflineLibraryStore.shared.isDownloaded(currentTrack.id) else { return false }
        if player.isPlaying { return true }
        do {
            try activateAudioSession()
            pauseSpotifyPlayer()
            let playing = player.play()
            if !playing { releaseAudioSession(deactivateStandaloneSession: true) }
            updateNowPlayingInfo()
            return playing
        } catch {
            return false
        }
    }

    public func togglePlayPause() {
        if isPlaying { pause() } else { _ = resume() }
    }

    public func seek(to time: TimeInterval) {
        guard time.isFinite, let player = audioPlayer else { return }
        player.currentTime = max(0, min(time, player.duration))
        updateNowPlayingInfo()
    }

    public func stop() {
        stop(releaseAudioSession: true)
    }

    func spotifyDidStartPlaying() {
        stop(releaseAudioSession: false)
    }

    private func stop(releaseAudioSession: Bool) {
        guard let player = audioPlayer else { return }
        player.delegate = nil
        player.stop()
        audioPlayer = nil
        currentTrack = nil
        OfflineSpotifyPlayback.setLocalVolumeOwner(false)
        playlistQueue.removeAll()
        history.removeAll()
        currentIndex = -1
        for (command, target, wasEnabled) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = wasEnabled
        }
        commandTargets.removeAll()
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == playerInfoID {
            center.nowPlayingInfo = releaseAudioSession ? previousNowPlayingInfo : nil
        }
        previousNowPlayingInfo = nil
        self.releaseAudioSession(deactivateStandaloneSession: releaseAudioSession)
        OfflineGlobalPlayerOverlay.shared.hide()
        notifyChange()
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self, weak player] in
            guard let self, let player, player === self.audioPlayer else { return }
            if flag, self.isRepeatEnabled, let track = self.currentTrack, OfflineLibraryStore.shared.isDownloaded(track.id) {
                self.seek(to: 0)
                if self.resume() { return }
            }
            if !self.playNext() { self.stop() }
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let acquiredLease = spotifySessionLease == nil ? OfflineSpotifyPlayback.acquireAudioSession() : nil
        if let acquiredLease { spotifySessionLease = acquiredLease }
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            if acquiredLease != nil { releaseAudioSession(deactivateStandaloneSession: false) }
            throw error
        }
    }

    private func releaseAudioSession(deactivateStandaloneSession: Bool) {
        if let lease = spotifySessionLease {
            spotifySessionLease = nil
            OfflineSpotifyPlayback.releaseAudioSession(lease)
        } else if deactivateStandaloneSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func pauseSpotifyPlayer() {
        guard let player = OfflineSpotifyPlayback.player ?? statefulPlayer as? NSObject else { return }
        if OfflineSpotifyPlayback.pause(player) { return }
        for name in ["pausePlayback", "pause", "stopPlayback", "stop"] {
            let selector = Selector(name)
            guard let method = class_getInstanceMethod(type(of: player), selector),
                  method_getNumberOfArguments(method) == 2 else { continue }
            let encoding = method_copyReturnType(method)
            defer { free(encoding) }
            guard encoding.pointee == 118 else { continue }
            typealias Action = @convention(c) (NSObject, Selector) -> Void
            let action = unsafeBitCast(method_getImplementation(method), to: Action.self)
            action(player, selector)
            return
        }
    }

    private func attachRemoteCommands() {
        guard commandTargets.isEmpty else { return }
        previousNowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { player, _ in player.resume() }
        register(center.pauseCommand) { player, _ in player.pause(); return true }
        register(center.togglePlayPauseCommand) { player, _ in
            if player.isPlaying { player.pause(); return true }
            return player.resume()
        }
        register(center.nextTrackCommand) { player, _ in player.playNext() }
        register(center.previousTrackCommand) { player, _ in player.playPrevious() }
        register(center.changePlaybackPositionCommand) { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return false }
            player.seek(to: event.positionTime)
            return true
        }
    }

    private func register(_ command: MPRemoteCommand, action: @escaping (OfflinePlaybackController, MPRemoteCommandEvent) -> Bool) {
        let wasEnabled = command.isEnabled
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            guard self != nil else { return .noActionableNowPlayingItem }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentTrack != nil else { return }
                _ = action(self, event)
            }
            return .success
        }
        commandTargets.append((command, target, wasEnabled))
    }

    private let playerInfoID = "eevee-offline"

    private func updateNowPlayingInfo() {
        guard let track = currentTrack, let player = audioPlayer else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyExternalContentIdentifier: playerInfoID
        ]
        info[MPMediaItemPropertyAlbumTitle] = track.album
        let cover = OfflineLibraryStore.storesDirectory.appendingPathComponent("\(track.id).jpg")
        if let image = UIImage(contentsOfFile: cover.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = nextIndices().contains {
            OfflineLibraryStore.shared.isDownloaded(playlistQueue[$0].id)
        }
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
