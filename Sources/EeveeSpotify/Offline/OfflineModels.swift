import Foundation

public func cleanHtmlEntities(_ string: String) -> String {
    var s = string
    s = s.replacingOccurrences(of: "&quot;", with: "\"")
    s = s.replacingOccurrences(of: "&#039;", with: "'")
    s = s.replacingOccurrences(of: "&#39;", with: "'")
    s = s.replacingOccurrences(of: "&#x27;", with: "'")
    s = s.replacingOccurrences(of: "&apos;", with: "'")
    s = s.replacingOccurrences(of: "&amp;", with: "&")
    s = s.replacingOccurrences(of: "&lt;", with: "<")
    s = s.replacingOccurrences(of: "&gt;", with: ">")
    s = s.replacingOccurrences(of: "&nbsp;", with: " ")
    s = s.replacingOccurrences(of: "&#8217;", with: "'")
    s = s.replacingOccurrences(of: "&#8216;", with: "'")
    s = s.replacingOccurrences(of: "&#8220;", with: "\"")
    s = s.replacingOccurrences(of: "&#8221;", with: "\"")
    s = s.replacingOccurrences(of: "&#8211;", with: "-")
    s = s.replacingOccurrences(of: "&#8212;", with: "-")
    if s.contains("&#") {
        s = s.replacingOccurrences(of: "&#[0-9]+;", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&#x[0-9a-fA-F]+;", with: "", options: .regularExpression)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum OfflinePlayerError: LocalizedError {
    case noSource
    case trackNotDownloaded
    case playbackFailed
    case resolveFailed
    case downloadCorrupted
    case wrongQuality
    case incompleteCollection

    public var errorDescription: String? {
        switch self {
        case .noSource, .resolveFailed: return "offline_error_source".localized
        case .trackNotDownloaded: return "offline_error_missing".localized
        case .playbackFailed: return "offline_error_playback".localized
        case .downloadCorrupted: return "offline_error_file".localized
        case .wrongQuality: return "offline_error_quality".localized
        case .incompleteCollection: return "offline_error_collection".localized
        }
    }
}

public enum OfflineSearchRegion: Int, Codable, CaseIterable, Sendable {
    case automatic, russia, europe

    var localizationKey: String {
        switch self {
        case .automatic: return "offline_region_auto"
        case .russia: return "offline_region_ru"
        case .europe: return "offline_region_eu"
        }
    }
}

public enum OfflineDownloadState: Equatable, Codable {
    case notDownloaded
    case downloading
    case downloaded
    case failed
}

public struct OfflineTrack: Identifiable, Codable, Equatable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String?
    public var duration: TimeInterval
    public var sourceURL: URL?
    var storedExtension: String?
    public var downloadState: OfflineDownloadState

    public init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval = 0,
        sourceURL: URL? = nil,
        downloadState: OfflineDownloadState = .notDownloaded
    ) {
        self.id = id
        self.title = cleanHtmlEntities(title)
        self.artist = cleanHtmlEntities(artist)
        self.album = album.map(cleanHtmlEntities)
        self.duration = duration
        self.sourceURL = sourceURL
        self.downloadState = downloadState
    }

    public var fileExtension: String {
        if let storedExtension, OfflineLibraryStore.audioExtensions.contains(storedExtension) { return storedExtension }
        for ext in OfflineLibraryStore.audioExtensions {
            let candidate = OfflineLibraryStore.storesDirectory.appendingPathComponent("\(id).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return ext
            }
        }
        return "m4a"
    }

    public var fileName: String {
        return "\(id).\(fileExtension)"
    }

    public var fileURL: URL {
        OfflineLibraryStore.storesDirectory.appendingPathComponent(fileName)
    }
}

public struct QueuedTrackItem: Codable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: TimeInterval?
    public let artwork: URL?

    public init(id: String, title: String, artist: String, album: String? = nil,
                duration: TimeInterval? = nil, artwork: URL? = nil) {
        self.id = id
        self.title = cleanHtmlEntities(title)
        self.artist = cleanHtmlEntities(artist)
        self.album = album.map(cleanHtmlEntities)
        self.duration = duration
        self.artwork = artwork
    }
}
