import Foundation

enum SponsorBlockReporterError: LocalizedError {
    case badURL
    case http(Int, String?)
    case transport(Error)
    case decode

    var errorDescription: String? {
        switch self {
        case .badURL:            return "Bad server URL"
        case .decode:            return "Could not decode server response"
        case .transport(let e):  return e.localizedDescription
        case .http(let code, let body):
            if let body, !body.isEmpty { return "HTTP \(code): \(body)" }
            return "HTTP \(code)"
        }
    }
}

extension UserDefaults {
    private static let sponsorBlockUserIDKey = "sponsorBlockUserID"

    static var sponsorBlockUserID: String {
        get {
            if let s = container.string(forKey: sponsorBlockUserIDKey), s.count >= 32 {
                return s
            }
            let fresh = SponsorBlockReporter.makeUserID()
            container.set(fresh, forKey: sponsorBlockUserIDKey)
            return fresh
        }
        set { container.set(newValue, forKey: sponsorBlockUserIDKey) }
    }
}

enum SponsorBlockReporter {
    static let userAgent = "EeveeSpotify/\(EeveeSpotify.version)"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 12
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func makeUserID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        out.reserveCapacity(36)
        for _ in 0..<36 { out.append(chars.randomElement()!) }
        return out
    }

    static func submitSegment(
        episodeID: String,
        start: Double,
        end: Double,
        category: String,
        actionType: String,
        videoDuration: Double?,
        completion: @escaping (Result<Void, SponsorBlockReporterError>) -> Void
    ) {
        let opts = UserDefaults.sponsorBlockOptions
        guard var components = URLComponents(string: opts.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            completion(.failure(.badURL)); return
        }
        components.path = "/api/skipSegments"

        // service=Spotify requires segments-array form; flat startTime/endTime returns 400.
        let segment: [String: Any] = [
            "segment":    [start, end],
            "category":   category,
            "actionType": actionType,
        ]
        var body: [String: Any] = [
            "service":   "Spotify",
            "videoID":   episodeID,
            "userID":    UserDefaults.sponsorBlockUserID,
            "segments":  [segment],
            "userAgent": userAgent,
        ]
        if let videoDuration, videoDuration > 0 {
            body["videoDuration"] = videoDuration
        }

        guard let url = components.url,
              let payload = try? JSONSerialization.data(withJSONObject: body)
        else { completion(.failure(.badURL)); return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = payload
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("EeveeSpotify-SponsorBlock/1", forHTTPHeaderField: "X-CLIENT-NAME")

        let payloadStr = String(data: payload, encoding: .utf8) ?? "<binary>"
        NSLog("[EeveeSpotify][SB][SUBMIT] POST %@ payload=%@", url.absoluteString, payloadStr)
        writeDebugLog("[SB][submit] POST \(url.absoluteString) payload=\(payloadStr)")
        session.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(.transport(err))); return }
            guard let http = resp as? HTTPURLResponse else {
                completion(.failure(.http(0, nil))); return
            }
            let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) }
            NSLog("[EeveeSpotify][SB][SUBMIT] <- %d body=%@", http.statusCode, bodyStr ?? "<nil>")
            writeDebugLog("[SB][submit] -> \(http.statusCode) body=\(bodyStr ?? "<nil>")")
            if (200..<300).contains(http.statusCode) {
                completion(.success(()))
            } else {
                completion(.failure(.http(http.statusCode, bodyStr)))
            }
        }.resume()
    }

    static func vote(
        uuid: String,
        type: SponsorBlockVote,
        completion: @escaping (Result<Void, SponsorBlockReporterError>) -> Void
    ) {
        sendVote(extraQuery: [URLQueryItem(name: "type", value: String(type.rawValue))],
                 uuid: uuid, completion: completion)
    }

    static func categoryVote(
        uuid: String,
        category: String,
        completion: @escaping (Result<Void, SponsorBlockReporterError>) -> Void
    ) {
        sendVote(extraQuery: [URLQueryItem(name: "category", value: category)],
                 uuid: uuid, completion: completion)
    }

    private static func sendVote(
        extraQuery: [URLQueryItem],
        uuid: String,
        completion: @escaping (Result<Void, SponsorBlockReporterError>) -> Void
    ) {
        let opts = UserDefaults.sponsorBlockOptions
        guard var components = URLComponents(string: opts.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            completion(.failure(.badURL)); return
        }
        components.path = "/api/voteOnSponsorTime"
        var q: [URLQueryItem] = [
            URLQueryItem(name: "UUID",   value: uuid),
            URLQueryItem(name: "userID", value: UserDefaults.sponsorBlockUserID),
        ]
        q.append(contentsOf: extraQuery)
        components.queryItems = q

        guard let url = components.url else { completion(.failure(.badURL)); return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("EeveeSpotify-SponsorBlock/1", forHTTPHeaderField: "X-CLIENT-NAME")

        writeDebugLog("[SB][vote] POST \(url.absoluteString)")
        session.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(.transport(err))); return }
            guard let http = resp as? HTTPURLResponse else {
                completion(.failure(.http(0, nil))); return
            }
            let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) }
            writeDebugLog("[SB][vote] -> \(http.statusCode) body=\(bodyStr ?? "<nil>")")
            if (200..<300).contains(http.statusCode) {
                completion(.success(()))
            } else {
                completion(.failure(.http(http.statusCode, bodyStr)))
            }
        }.resume()
    }
}
