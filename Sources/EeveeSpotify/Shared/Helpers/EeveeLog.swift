import Foundation

// Console + the exportable debug log file (Settings → Troubleshooting → Export debug log).
enum EeveeLog {
    static let path = NSTemporaryDirectory() + "eeveespotify_debug.log"
    private static let limit: UInt64 = 2 << 20
    private static let queue = DispatchQueue(label: "EeveeSpotify.log", qos: .utility)
    private static var handle: FileHandle?
    private static var headerWritten = false

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ line: String) {
        NSLog("%@", line)
        guard UserDefaults.debugLoggingEnabled else { return }
        let date = Date()
        queue.async { append("\(stamp.string(from: date)) \(line)\n") }
    }

    static func checkpoint(_ line: String) {
        guard UserDefaults.debugLoggingEnabled else { return }
        let date = Date()
        queue.sync { append("\(stamp.string(from: date)) \(line)\n") }
    }

    static func clear() {
        queue.async {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8), let file = openHandle() else { return }
        try? file.write(contentsOf: data)
        if let offset = try? file.offset(), offset > limit { trim(file) }
    }

    private static func openHandle() -> FileHandle? {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let file = FileHandle(forUpdatingAtPath: path) else { return nil }
        _ = try? file.seekToEnd()
        handle = file
        if !headerWritten {
            headerWritten = true
            let header = "\n===== launch · EeveeSpotify \(EeveeSpotify.version) · Spotify \(EeveeSpotify.spotifyVersion) · iOS \(ProcessInfo.processInfo.operatingSystemVersionString) =====\n"
            if let data = header.data(using: .utf8) { try? file.write(contentsOf: data) }
        }
        return file
    }

    // Keeps the newest half so a long session never grows the file past the limit.
    private static func trim(_ file: FileHandle) {
        guard (try? file.seek(toOffset: limit / 2)) != nil,
              var tail = try? file.readToEnd() else { return }
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: newline)...] }
        try? file.truncate(atOffset: 0)
        try? file.write(contentsOf: tail)
    }
}

func eeveeLog(_ format: String, _ args: CVarArg...) {
    EeveeLog.write(args.isEmpty ? format : String(format: format, arguments: args))
}
