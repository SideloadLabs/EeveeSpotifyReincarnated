import Foundation
import Orion
import MediaPlayer
import AVFoundation
import UIKit

struct LockScreenArtworkGroup: HookGroup {}

@available(iOS 26.0, *)
final class LockScreenArtworkController {
    static let shared = LockScreenArtworkController()

    private let lock = NSLock()
    private var pollTimer: Timer?

    private var wantedTrackId: String?
    private var artwork: MPMediaItemAnimatedArtwork?
    private var artworkKey: String?

    private init() {}

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startPolling()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollForTrackChange()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private var lastPolledTrackId: String?

    private func pollForTrackChange() {
        guard UserDefaults.animatedLockScreenArtwork else {
            if lastPolledTrackId != nil {
                lastPolledTrackId = nil
                clear(reason: "switched off")
            }
            return
        }
        guard let trackId = KaraokePlaybackTracker.shared.currentTrackId(), trackId != lastPolledTrackId else { return }
        lastPolledTrackId = trackId
        resolve(trackId: trackId)
    }

    // MARK: - Which key this iOS wants a clip under

    private static func animatedArtworkKey() -> (key: String, aspect: CGFloat)? {
        let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
            return (MPNowPlayingInfoProperty3x4AnimatedArtwork, 3.0 / 4.0)
        }
        if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
            return (MPNowPlayingInfoProperty1x1AnimatedArtwork, 1)
        }
        return nil
    }

    private static func artwork(
        artworkID: String,
        file: URL,
        still: UIImage?
    ) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(
            artworkID: artworkID,
            previewImageRequestHandler: { size, done in
                if let still = still {
                    done(still)
                } else {
                    let renderer = UIGraphicsImageRenderer(size: size)
                    done(renderer.image { $0.cgContext.setFillColor(UIColor.darkGray.cgColor); $0.fill(CGRect(origin: .zero, size: size)) })
                }
            },
            videoAssetFileURLRequestHandler: { _, done in
                done(file)
            }
        )
    }

    // MARK: - Resolving a track's clip

    private func clear(reason: String) {
        LockScreenArtworkFile.cancelFetch()
        lock.lock()
        wantedTrackId = nil
        artwork = nil
        artworkKey = nil
        lock.unlock()
        writeDebugLog("[LockScreenArtwork] cleared: \(reason)")
        resend()
    }

    private func resolve(trackId: String) {
        guard let (key, aspect) = LockScreenArtworkController.animatedArtworkKey() else {
            writeDebugLog("[LockScreenArtwork] no supported animated artwork key on this iOS")
            return
        }

        LockScreenArtworkFile.cancelFetch()
        lock.lock()
        wantedTrackId = trackId
        artwork = nil
        artworkKey = nil
        lock.unlock()

        let uri = "spotify:track:\(trackId)"

        if let track = statefulPlayer?.currentTrack(),
           track.URI().spt_trackIdentifier() == trackId {
            let metadata = track.metadata()
            if let canvas = SpotifyCanvazAPI.canvas(fromTrackMetadata: metadata), canvas.isVideo {
                writeDebugLog("[LockScreenArtwork] using track metadata canvas for \(trackId)")
                play(trackId: trackId, uri: uri, canvas: canvas, aspect: aspect, key: key)
                return
            }
        }

        askCanvaz(uri: uri) { [weak self] canvas, note in
            guard let self = self else { return }
            self.lock.lock()
            let stillWanted = self.wantedTrackId == trackId
            self.lock.unlock()
            guard stillWanted else { return }

            guard let canvas = canvas, canvas.isVideo else {
                writeDebugLog("[LockScreenArtwork] no clip for \(trackId): \(note)")
                return
            }
            self.play(trackId: trackId, uri: uri, canvas: canvas, aspect: aspect, key: key)
        }
    }

    private func play(trackId: String, uri: String, canvas: SpotifyCanvas, aspect: CGFloat, key: String) {
        writeDebugLog("[LockScreenArtwork] clip for \(uri): \(canvas.address)")
        LockScreenArtworkFile.fetch(identifier: canvas.identifier, address: canvas.address) { [weak self] file, note in
            guard let self = self else { return }
            writeDebugLog("[LockScreenArtwork] \(canvas.identifier) \(note)")
            guard let file = file else { return }

            LockScreenArtworkFile.crop(file: file, identifier: canvas.identifier, aspect: aspect) { cropped, cropNote in
                writeDebugLog("[LockScreenArtwork] \(canvas.identifier) \(cropNote)")
                guard let ready = cropped else { return }

                LockScreenArtworkFile.firstFrame(of: ready) { frame in
                    let still = frame.map { UIImage(cgImage: $0) }
                    DispatchQueue.main.async {
                        self.lock.lock()
                        let stillWanted = self.wantedTrackId == trackId
                        self.lock.unlock()
                        guard stillWanted else { return }

                        let built = LockScreenArtworkController.artwork(
                            artworkID: canvas.identifier + uri,
                            file: ready,
                            still: still
                        )
                        self.lock.lock()
                        self.artwork = built
                        self.artworkKey = key
                        self.lock.unlock()
                        writeDebugLog("[LockScreenArtwork] \(uri) set under \(key)")
                        self.resend()
                    }
                }
            }
        }
    }

    private func askCanvaz(uri: String, done: @escaping (SpotifyCanvas?, String) -> Void) {
        guard let token = spotifyAccessToken else {
            done(nil, "no token for canvaz yet")
            return
        }
        guard let url = URL(string: "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases") else {
            done(nil, "bad canvaz URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = SpotifyCanvazAPI.requestBody(trackURI: uri)
        request.allowsConstrainedNetworkAccess = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let canvas = data.flatMap { SpotifyCanvazAPI.canvas(from: $0) }
            let note = "canvaz status \(status), \(data?.count ?? 0) bytes, error \(error?.localizedDescription ?? "none")"
            DispatchQueue.main.async { done(canvas, note) }
        }.resume()
    }

    // MARK: - Applying the artwork to every outgoing info dictionary

    func currentArtworkEntry() -> (artwork: MPMediaItemAnimatedArtwork, key: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let artwork = artwork, let key = artworkKey else { return nil }
        return (artwork, key)
    }

    private func resend() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        if let (artwork, key) = currentArtworkEntry() {
            info[key] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

@available(iOS 26.0, *)
class MPNowPlayingInfoCenterLockScreenArtworkHook: ClassHook<MPNowPlayingInfoCenter> {
    typealias Group = LockScreenArtworkGroup

    func setNowPlayingInfo(_ nowPlayingInfo: [String: Any]?) {
        guard var info = nowPlayingInfo,
              let (artwork, key) = LockScreenArtworkController.shared.currentArtworkEntry() else {
            orig.setNowPlayingInfo(nowPlayingInfo)
            return
        }
        info[key] = artwork
        orig.setNowPlayingInfo(info)
    }
}

func activateLockScreenArtworkHooks() {
    guard #available(iOS 26.0, *) else {
        writeDebugLog("[LockScreenArtwork] off: needs iOS 26")
        return
    }
    guard NSClassFromString("MPMediaItemAnimatedArtwork") != nil,
          NSClassFromString("MPNowPlayingInfoCenter") != nil else {
        writeDebugLog("[LockScreenArtwork] off: MPMediaItemAnimatedArtwork/MPNowPlayingInfoCenter unavailable")
        return
    }
    LockScreenArtworkGroup().activate()
    LockScreenArtworkController.shared.start()
    writeDebugLog("[LockScreenArtwork] activated")
}
