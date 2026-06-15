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
    var apiUrl: String
    private let session: URLSession

    private init(apiUrl: String) {
        self.apiUrl = apiUrl
        
        let configuration = URLSessionConfiguration.ephemeral
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
    
    static let shared = LrclibLyricsRepository(
        apiUrl: UserDefaults.lyricsOptions.lrclibUrl
    )
    
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

        let task = session.dataTask(with: request) { responseData, _, err in
            error = err
            data = responseData
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if error != nil, request.url != url {
            // IPv4-direct attempt failed; retry with the original hostname URL.
            writeDebugLog("[LRCLIB] IPv4-direct attempt failed (\(error!)), retrying via hostname")

            let fallbackSemaphore = DispatchSemaphore(value: 0)
            var fallbackRequest = URLRequest(url: url)
            fallbackRequest.setValue(
                "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify",
                forHTTPHeaderField: "User-Agent"
            )

            let fallbackTask = session.dataTask(with: fallbackRequest) { response, _, err in
                error = err
                data = response
                fallbackSemaphore.signal()
            }

            fallbackTask.resume()
            fallbackSemaphore.wait()
        }

        if let error = error {
            writeDebugLog("[LRCLIB] Request error for \(stringUrl): \(error)")
            throw error
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
    
    private func mapSyncedLyricsLines(_ lines: [String]) -> [LyricsLineDto] {
        return lines.compactMap { line in
            guard let match = line.firstMatch(
                "\\[(?<minute>\\d*):(?<seconds>\\d+\\.\\d+|\\d+)\\] ?(?<content>.*)"
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
            
            let minute = Int(captures["minute"]!)!
            let seconds = Float(captures["seconds"]!)!
            let content = captures["content"]!
            
            return LyricsLineDto(
                content: content.lyricsNoteIfEmpty,
                offsetMs: Int(minute * 60 * 1000 + Int(seconds * 1000))
            )
        }
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let song: LrclibSong

        do {
            song = try getSong(trackName: query.title, artistName: query.primaryArtist)
        } catch {
            let strippedTitle = query.title.strippedTrackTitle
            do {
                song = try getSong(trackName: strippedTitle, artistName: query.primaryArtist)
            } catch {
                throw LyricsError.noSuchSong
            }
        }

        if song.instrumental {
            return LyricsDto(
                lines: [],
                timeSynced: false,
                romanization: .original
            )
        }

        if let syncedLyrics = song.syncedLyrics, !syncedLyrics.isEmpty {
            let lines = Array(syncedLyrics.components(separatedBy: "\n").dropLast())
            return LyricsDto(
                lines: mapSyncedLyricsLines(lines),
                timeSynced: true,
                romanization: lines.canBeRomanized ? .canBeRomanized : .original
            )
        }
        
        guard let plainLyrics = song.plainLyrics, !plainLyrics.isEmpty else {
            return LyricsDto(
                lines: [],
                timeSynced: false,
                romanization: .original
            )
        }
        
        let lines = Array(plainLyrics.components(separatedBy: "\n").dropLast())
        
        return LyricsDto(
            lines: lines.map { content in LyricsLineDto(content: content) },
            timeSynced: false,
            romanization: lines.canBeRomanized ? .canBeRomanized : .original
        )
    }
}