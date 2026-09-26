import Foundation
import AVFoundation
import CoreGraphics

enum LockScreenArtworkFile {
    private static let cacheCapBytes: UInt64 = 120 * 1024 * 1024
    private static let aspectSlack: CGFloat = 0.02

    private static let queue = DispatchQueue(label: "com.eevee.lockscreenartwork", qos: .utility)
    private static var currentTask: URLSessionDownloadTask?

    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("EeveeSpotify/LockScreenArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func file(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    // Kept alive by use, so the file the lock screen is currently playing
    // is the last one pruning would ever pick.
    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        func size(_ url: URL) -> UInt64 { UInt64((try? url.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0) }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast }

        var total = files.reduce(UInt64(0)) { $0 + size($1) }
        guard total > cacheCapBytes else { return }
        for file in files.sorted(by: { modified($0) < modified($1) }) {
            guard total > cacheCapBytes else { break }
            total -= size(file)
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func cancelFetch() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Downloads (or reuses a cached copy of) the clip at `address`.
    static func fetch(identifier: String, address: String, done: @escaping (URL?, String) -> Void) {
        cancelFetch()
        guard let remote = URL(string: address) else {
            done(nil, "no address")
            return
        }
        let local = file(named: "\(identifier).mp4")
        if FileManager.default.fileExists(atPath: local.path) {
            queue.async {
                touch(local)
                done(local, "cached")
            }
            return
        }

        var request = URLRequest(url: remote)
        // Low Data Mode marks the path constrained; failing outright here
        // matches the original rather than silently spending the user's data.
        request.allowsConstrainedNetworkAccess = false
        let task = URLSession.shared.downloadTask(with: request) { temporary, response, error in
            guard let temporary = temporary else {
                done(nil, "download failed: \(error?.localizedDescription ?? "unknown error")")
                return
            }
            let length = response?.expectedContentLength ?? -1
            queue.async {
                try? FileManager.default.removeItem(at: local)
                do {
                    try FileManager.default.moveItem(at: temporary, to: local)
                    prune()
                    done(local, "downloaded \(length / 1024) KB")
                } catch {
                    done(nil, "not kept: \(error.localizedDescription)")
                }
            }
        }
        currentTask = task
        task.resume()
    }

    // MARK: Cropping

    private static func even(_ value: CGFloat) -> CGFloat { 2 * (value / 2).rounded(.down) }

    /// The size the clip is actually shown at (rotation applied), and the
    /// transform that puts its top-left corner at the origin.
    private static func shownSize(of track: AVAssetTrack) -> (size: CGSize, upright: CGAffineTransform) {
        let shown = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        let upright = track.preferredTransform.concatenating(
            CGAffineTransform(translationX: -shown.minX, y: -shown.minY)
        )
        return (CGSize(width: abs(shown.width), height: abs(shown.height)), upright)
    }

    static func crop(file source: URL, identifier: String, aspect: CGFloat, done: @escaping (URL?, String) -> Void) {
        let into = file(named: String(format: "%@-%.2f.mp4", identifier, aspect))
        if FileManager.default.fileExists(atPath: into.path) {
            queue.async {
                touch(into)
                done(into, "cropped already")
            }
            return
        }

        let asset = AVURLAsset(url: source)
        asset.loadTracks(withMediaType: .video) { tracks, error in
            queue.async {
                guard let track = tracks?.first else {
                    done(nil, "no video track: \(error?.localizedDescription ?? "unknown error")")
                    return
                }
                let (shown, upright) = shownSize(of: track)
                guard shown.width >= 2, shown.height >= 2 else {
                    done(nil, "no picture")
                    return
                }
                guard abs(shown.width / shown.height - aspect) >= aspectSlack else {
                    done(source, "already the right shape")
                    return
                }

                let render = shown.width / shown.height > aspect
                    ? CGSize(width: even(shown.height * aspect), height: even(shown.height))
                    : CGSize(width: even(shown.width), height: even(shown.width / aspect))

                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(
                    upright.concatenating(CGAffineTransform(
                        translationX: (render.width - shown.width) / 2,
                        y: (render.height - shown.height) / 2
                    )),
                    at: .zero
                )
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = track.timeRange
                instruction.layerInstructions = [layer]

                let composition = AVMutableVideoComposition()
                composition.renderSize = render
                let frameRate = track.nominalFrameRate > 1 ? Int32(track.nominalFrameRate.rounded()) : 30
                composition.frameDuration = CMTime(value: 1, timescale: frameRate)
                composition.instructions = [instruction]

                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                    done(nil, "no exporter")
                    return
                }
                export.outputURL = into
                export.outputFileType = .mp4
                export.videoComposition = composition
                export.exportAsynchronously {
                    queue.async {
                        if export.status == .completed {
                            prune()
                            done(into, "cropped to \(Int(render.width))x\(Int(render.height))")
                        } else {
                            done(nil, "crop failed: \(export.error?.localizedDescription ?? "unknown error")")
                        }
                    }
                }
            }
        }
    }

    /// The clip's first frame — what the system wants the preview still to
    /// match. `done` is called on an arbitrary queue with nil if unreadable.
    static func firstFrame(of file: URL, done: @escaping (CGImage?) -> Void) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            done(image)
        }
    }
}
