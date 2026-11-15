import AudioToolbox
import AVFoundation
import Foundation

enum OfflineAudioFile {
    static func validate(_ url: URL, lossless: Bool, expected: TimeInterval) throws -> TimeInterval {
        try inspect(url, lossless: lossless, expected: expected, allowLowerQuality: false).duration
    }

    static func inspect(_ url: URL, lossless: Bool, expected: TimeInterval,
                        allowLowerQuality: Bool) throws -> (duration: TimeInterval, bitrate: UInt32) {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else {
            throw OfflinePlayerError.downloadCorrupted
        }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr else {
            throw OfflinePlayerError.downloadCorrupted
        }
        let requiredCodec = lossless ? kAudioFormatFLAC : kAudioFormatMPEGLayer3
        let isAAC = !lossless && allowLowerQuality && url.pathExtension == "m4a"
            && format.mFormatID == kAudioFormatMPEG4AAC
        guard format.mFormatID == requiredCodec || isAAC else { throw OfflinePlayerError.wrongQuality }
        var bitrate: UInt32 = 0
        if !lossless {
            size = UInt32(MemoryLayout.size(ofValue: bitrate))
            guard AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitrate) == noErr,
                  (allowLowerQuality ? (120_000...325_000) : (315_000...325_000)).contains(bitrate)
            else { throw OfflinePlayerError.wrongQuality }
        }

        var decoded: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &decoded) == noErr, let decoded else {
            throw OfflinePlayerError.downloadCorrupted
        }
        defer { ExtAudioFileDispose(decoded) }
        var length: Int64 = 0
        size = UInt32(MemoryLayout.size(ofValue: length))
        guard ExtAudioFileGetProperty(decoded, kExtAudioFileProperty_FileLengthFrames, &size, &length) == noErr,
              (1...8).contains(format.mChannelsPerFrame), (8_000...384_000).contains(format.mSampleRate)
        else { throw OfflinePlayerError.downloadCorrupted }
        let duration = Double(length) / format.mSampleRate
        guard OfflineRecordingMatch.duration(duration, matches: expected),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate,
                                      channels: format.mChannelsPerFrame, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024)
        else { throw OfflinePlayerError.downloadCorrupted }
        var clientFormat = pcm.streamDescription.pointee
        size = UInt32(MemoryLayout.size(ofValue: clientFormat))
        guard ExtAudioFileSetProperty(decoded, kExtAudioFileProperty_ClientDataFormat, size, &clientFormat) == noErr
        else { throw OfflinePlayerError.downloadCorrupted }
        buffer.frameLength = buffer.frameCapacity
        var frames = buffer.frameCapacity
        guard ExtAudioFileRead(decoded, &frames, buffer.mutableAudioBufferList) == noErr, frames > 0,
              ExtAudioFileSeek(decoded, max(0, length - Int64(buffer.frameCapacity))) == noErr
        else { throw OfflinePlayerError.downloadCorrupted }
        buffer.frameLength = buffer.frameCapacity
        frames = buffer.frameCapacity
        guard ExtAudioFileRead(decoded, &frames, buffer.mutableAudioBufferList) == noErr, frames > 0
        else { throw OfflinePlayerError.downloadCorrupted }
        return (duration, bitrate)
    }

    static func compactCopy(of source: URL) async throws -> URL {
        let destination = source.deletingPathExtension().appendingPathExtension("m4a")
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw OfflinePlayerError.wrongQuality
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        try Task.checkCancellation()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: destination)
            try Task.checkCancellation()
            throw OfflinePlayerError.downloadCorrupted
        }
        return destination
    }
}
