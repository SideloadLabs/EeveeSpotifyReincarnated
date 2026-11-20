import Foundation

private class LrclibTLSDelegate: NSObject, URLSessionTaskDelegate {
    let expectedHost: String

    init(expectedHost: String) {
        self.expectedHost = expectedHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Build a fresh trust object from the peer's certificate chain, evaluated
        // against the original hostname. Re-using and mutating the trust object
        // supplied by URLSession for a raw-IP connection can fail chain building
        // (errSSLXCertChainInvalid / -9802) even when the certificate is valid.
        //
        // SecTrustGetCertificateAtIndex is deprecated in iOS 15 and returns nil on
        // iOS 16+ / iOS 26+. Use SecTrustCopyCertificateChain where available.
        //
        // FIX: SecTrustCopyCertificateChain returns a plain CFTypeRef/CFArray on
        // iOS 26; the Swift conditional cast `as? [SecCertificate]` can silently
        // return nil on some OS builds when the bridging isn't automatic.
        // Use CFArrayGetCount / CFArrayGetValueAtIndex to extract the chain safely.
        guard let request = task.currentRequest,
              request.value(forHTTPHeaderField: "Host") == expectedHost,
              request.url?.host == challenge.protectionSpace.host,
              request.url?.host != expectedHost else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let certChain: [SecCertificate]
        if #available(iOS 15.0, *) {
            guard let chainRef = SecTrustCopyCertificateChain(serverTrust) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let count = CFArrayGetCount(chainRef)
            guard count > 0 else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            certChain = (0..<count).compactMap { i in
                CFArrayGetValueAtIndex(chainRef, i)
                    .map { Unmanaged<SecCertificate>.fromOpaque($0).takeUnretainedValue() }
            }
        } else {
            let count = SecTrustGetCertificateCount(serverTrust)
            guard count > 0 else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            certChain = (0..<count).compactMap { SecTrustGetCertificateAtIndex(serverTrust, $0) }
            guard !certChain.isEmpty else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }

        let policy = SecPolicyCreateSSL(true, expectedHost as CFString)

        var freshTrust: SecTrust?
        guard SecTrustCreateWithCertificates(certChain as CFArray, policy, &freshTrust) == errSecSuccess,
              let freshTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var error: CFError?
        if SecTrustEvaluateWithError(freshTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: freshTrust))
        } else {
            writeDebugLog("[LRCLIB] TLS validation failed for \(expectedHost): \(String(describing: error))")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private func resolveIPv4(_ host: String) -> String? {
    var hints = addrinfo(
        ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
        ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?

    guard getaddrinfo(host, nil, &hints, &result) == 0, let addr = result else {
        return nil
    }
    defer { freeaddrinfo(result) }

    var ipBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let sockaddrIn = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
    var sinAddr = sockaddrIn.pointee.sin_addr

    guard inet_ntop(AF_INET, &sinAddr, &ipBuffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
        return nil
    }

    return String(cString: ipBuffer)
}

class LrclibLyricsRepository: LyricsRepository {
    private let apiUrl: String
    private let session: URLSession

    init(apiUrl: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.apiUrl = apiUrl
        
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify"
        ]
        // FIX: 4 seconds is far too short — LRCLIB can be slow to respond,
        // and the IPv4-direct attempt + fallback each consumed the full 4s in
        // the debug log, causing guaranteed timeouts. Use 10s instead.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false

        if let host = URL(string: apiUrl)?.host {
            session = URLSession(
                configuration: configuration,
                delegate: LrclibTLSDelegate(expectedHost: host),
                delegateQueue: nil
            )
        } else {
            session = URLSession(configuration: configuration)
        }
    }
    
    static let originalApiUrl = "https://lrclib.net/api"
    
    private static let lock = NSLock()
    private static var current: LrclibLyricsRepository?
    static var shared: LrclibLyricsRepository {
        let url = UserDefaults.lyricsOptions.lrclibUrl
        lock.lock(); defer { lock.unlock() }
        if let current, current.apiUrl == url { return current }
        let repository = LrclibLyricsRepository(apiUrl: url)
        current = repository
        return repository
    }

    deinit { session.finishTasksAndInvalidate() }
    
    private func perform(
        _ path: String, 
        query: [String:Any] = [:]
    ) throws -> Data {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }
        
        guard let url = URL(string: stringUrl) else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)

        // Some networks have broken/unroutable IPv6 paths to lrclib.net that cause
        // ETIMEDOUT at the TCP layer for custom URLSession instances. Resolve to
        // an IPv4 address explicitly and connect to it directly (TLS hostname
        // validation against the original host is handled by LrclibTLSDelegate).
        if let host = url.host, let ip = resolveIPv4(host) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = ip
            if let ipUrl = components?.url {
                request = URLRequest(url: ipUrl)
                request.setValue(host, forHTTPHeaderField: "Host")
            }
        }

        request.setValue(
            "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify",
            forHTTPHeaderField: "User-Agent"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        var httpResponse: URLResponse?
        var responseRequest = request
        try LyricsDownloadHTTP.prepare(request)
        let task = session.dataTask(with: request) { responseData, response, err in
            error = err
            data = responseData
            httpResponse = response
            semaphore.signal()
        }

        try LyricsDownloadHTTP.start(task)
        try LyricsDownloadHTTP.waitForResponse(semaphore, task: task)

        if let firstError = error, (firstError as? URLError)?.code != .notConnectedToInternet,
           (firstError as? URLError)?.code != .cancelled, request.url != url {
            // IPv4-direct attempt failed; retry with the original hostname URL.
            writeDebugLog("[LRCLIB] IPv4-direct attempt failed (\(firstError)), retrying via hostname")

            let fallbackSemaphore = DispatchSemaphore(value: 0)
            var fallbackRequest = URLRequest(url: url)
            fallbackRequest.setValue(
                "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify",
                forHTTPHeaderField: "User-Agent"
            )

            try LyricsDownloadHTTP.prepare(fallbackRequest)
            responseRequest = fallbackRequest
            let fallbackTask = session.dataTask(with: fallbackRequest) { response, urlResponse, err in
                error = err
                data = response
                httpResponse = urlResponse
                fallbackSemaphore.signal()
            }

            try LyricsDownloadHTTP.start(fallbackTask)
            try LyricsDownloadHTTP.waitForResponse(fallbackSemaphore, task: fallbackTask)
        }

        if let error = error {
            writeDebugLog("[LRCLIB] Request error for \(stringUrl): \(error)")
            throw error
        }
        try LyricsDownloadHTTP.validate(httpResponse, request: responseRequest)

        if let http = httpResponse as? HTTPURLResponse {
            if http.statusCode == 404 { throw LyricsError.noSuchSong }
            guard (200..<300).contains(http.statusCode) else { throw LyricsProviderHTTPError(status: http.statusCode) }
        }
        guard let data else {
            writeDebugLog("[LRCLIB] No data returned for \(stringUrl)")
            throw LyricsError.decodingError
        }
        writeDebugLog("[LRCLIB] \(stringUrl) -> \(data.count) bytes")
        return data
    }
    
    private func getSong(trackName: String, artistName: String) throws -> LrclibSong {
        let data: Data = try perform("/get", query: [
            "track_name": trackName,
            "artist_name": artistName
        ])
        do {
            return try JSONDecoder().decode(LrclibSong.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            writeDebugLog("[LRCLIB] Decode error for \(trackName)/\(artistName): \(error). Body: \(body.prefix(300))")
            throw error
        }
    }
    
    private static func mapSyncedLyricsLines(_ lines: [String]) -> [LyricsLineDto] {
        return lines.compactMap { line in
            guard let match = line.firstMatch(
                "\\[(?<minute>\\d+):(?<seconds>\\d+\\.\\d+|\\d+)\\] ?(?<content>.*)"
            ) else {
                return nil
            }
            
            var captures: [String: String] = [:]
            
            for name in ["minute", "seconds", "content"] {
                let matchRange = match.range(withName: name)
                
                if let substringRange = Range(matchRange, in: line) {
                    captures[name] = String(line[substringRange])
                }
            }
            
            guard let minute = captures["minute"].flatMap(Double.init),
                  let seconds = captures["seconds"].flatMap(Double.init),
                  let content = captures["content"] else { return nil }
            let milliseconds = ((minute * 60 + seconds) * 1000).rounded()
            guard milliseconds <= Double(Int32.max) else { return nil }
            return LyricsLineDto(content: content.lyricsNoteIfEmpty, offsetMs: Int(milliseconds))
        }
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let song: LrclibSong

        do {
            song = try getSong(trackName: query.title, artistName: query.primaryArtist)
        } catch LyricsError.noSuchSong {
            let stripped = query.title.strippedTrackTitle
            guard !stripped.isEmpty, stripped != query.title else { throw LyricsError.noSuchSong }
            song = try getSong(trackName: stripped, artistName: query.primaryArtist)
        }
        return try Self.lyrics(from: song)
    }

    static func lyrics(from song: LrclibSong) throws -> LyricsDto {
        if song.instrumental {
            return LyricsDto(
                lines: [],
                timeSynced: false,
                romanization: .original
            )
        }

        if let synced = song.syncedLyrics {
            let parsed = mapSyncedLyricsLines(synced.components(separatedBy: "\n"))
            if !parsed.isEmpty {
                return LyricsDto(lines: parsed, timeSynced: true,
                                 romanization: parsed.map(\.content).canBeRomanized ? .canBeRomanized : .original)
            }
        }

        guard let plain = song.plainLyrics?.trimmingCharacters(in: .newlines),
              !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LyricsError.decodingError }
        let lines = plain.components(separatedBy: "\n")
        return LyricsDto(lines: lines.map { LyricsLineDto(content: $0) }, timeSynced: false,
                         romanization: lines.canBeRomanized ? .canBeRomanized : .original)
    }
}
