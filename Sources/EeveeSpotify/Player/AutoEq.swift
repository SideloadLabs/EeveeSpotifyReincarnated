import Foundation

// headphone corrections from AutoEq (github.com/jaakkopasanen/AutoEq, MIT, Jaakko Pasanen), read from its public
// repository when asked for: the index of its results, cached for a month, and a headphone's parametric file.
//
// results/INDEX.md is a heading and a note, then a line per result:
//     - [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650) by oratory1990
// and the folder holds "<folder's last part> ParametricEQ.txt": a "Preamp: -6.1 dB" line, then lines like
//     Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
enum AutoEq {
    struct Headphone: Identifiable, Hashable {
        let name: String
        let source: String
        let path: String
        fileprivate let foldedName: String
        fileprivate let folded: String

        var id: String { path }
    }

    private static let results = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    private static let indexLife: TimeInterval = 30 * 24 * 3600

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private static var cacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EeveeSpotify/AutoEq/INDEX.md")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func parseIndex(_ markdown: String) -> [Headphone] {
        var headphones = [Headphone]()
        markdown.enumerateLines { line, _ in
            guard line.hasPrefix("- [") else { return }
            // the last "](./" and the last ") by ": names hold brackets, folders parentheses.
            guard let link = line.range(of: "](./", options: .backwards),
                  let by = line.range(of: ") by ", options: .backwards),
                  by.lowerBound > link.upperBound else { return }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<link.lowerBound])
            let path = String(line[link.upperBound..<by.lowerBound])
            let source = String(line[by.upperBound...])
            guard !name.isEmpty, !path.isEmpty else { return }
            headphones.append(Headphone(name: name, source: source, path: path, foldedName: fold(name), folded: fold("\(name) \(source)")))
        }
        return headphones
    }

    // the headphones holding every word of `query` in their name or source, case and accents aside; those with
    // every word in the name first ("airpods pro 2" isn't the AirPods Pro measured on a 5128).
    static func search(_ all: [Headphone], _ query: String) -> [Headphone] {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        let found = all.filter { headphone in words.allSatisfy { headphone.folded.contains($0) } }
        let byName = found.filter { headphone in words.allSatisfy { headphone.foldedName.contains($0) } }
        return byName.count == found.count ? found : byName + found.filter { headphone in !words.allSatisfy { headphone.foldedName.contains($0) } }
    }

    // the index, from the cache unless `refresh` or it's a month old, else from GitHub; the cache still answers
    // when GitHub doesn't. `done` runs on the main queue, with the error when GitHub didn't answer.
    static func loadIndex(refresh: Bool = false, done: @escaping ([Headphone], String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let cached = cacheFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(parseIndex) ?? []
            let age = cacheFile.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
                .map { -$0.timeIntervalSinceNow } ?? .infinity
            if !refresh, !cached.isEmpty, age < indexLife {
                DispatchQueue.main.async { done(cached, nil) }
                return
            }
            guard let url = URL(string: results + "INDEX.md") else { return }
            session.dataTask(with: url) { data, response, error in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                let text = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
                let fetched = text.map(parseIndex) ?? []
                if let text, !fetched.isEmpty, let file = cacheFile {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? text.write(to: file, atomically: true, encoding: .utf8)
                }
                let why = fetched.isEmpty ? (error?.localizedDescription ?? "autoeq_unreadable".localized) : nil
                DispatchQueue.main.async { done(fetched.isEmpty ? cached : fetched, why) }
            }.resume()
        }
    }

    // the folder decoded and encoded again: the index leaves some characters raw ("&", parentheses) that are
    // safer escaped.
    static func parametricURL(_ path: String) -> URL? {
        let folder = path.removingPercentEncoding ?? path
        let file = "\(folder)/\((folder as NSString).lastPathComponent) ParametricEQ.txt"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return file.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: results + $0) }
    }

    // a parametric file's filters, nil when a filter that's on is of a kind this doesn't know, or there are none.
    static func parseParametric(_ text: String) -> [ParametricFilter]? {
        let pattern = #"^Filter\s+\d+:\s+ON\s+([A-Z]+)\s+Fc\s+([0-9.]+)\s*Hz\s+Gain\s+(-?[0-9.]+)\s*dB\s+Q\s+([0-9.]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        var filters = [ParametricFilter]()
        var unknown = false
        let range = NSRange(text.startIndex..., in: text)
        expression.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            let field = { (index: Int) in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
            let kind: ParametricFilter.Kind
            switch field(1) {
            case "PK", "PEQ": kind = .peak
            case "LSC", "LS": kind = .lowShelf
            case "HSC", "HS": kind = .highShelf
            default:
                unknown = true
                return
            }
            guard let frequency = Double(field(2)), let gain = Double(field(3)), let q = Double(field(4)) else {
                unknown = true
                return
            }
            filters.append(ParametricFilter(kind: kind, frequency: frequency, gain: gain, q: q))
        }
        return unknown || filters.isEmpty ? nil : filters
    }

    // the headphone's filters, or why not, on the main queue.
    static func download(_ headphone: Headphone, done: @escaping (Result<[ParametricFilter], DownloadError>) -> Void) {
        guard let url = parametricURL(headphone.path) else {
            done(.failure(DownloadError(message: "autoeq_unreadable".localized)))
            return
        }
        session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let filters = status == 200 ? data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(parseParametric) : nil
            DispatchQueue.main.async {
                if let filters {
                    done(.success(filters))
                } else {
                    done(.failure(DownloadError(message: error?.localizedDescription
                        ?? (status == 404 ? "autoeq_no_parametric".localized : "autoeq_unreadable".localized))))
                }
            }
        }.resume()
    }

    struct DownloadError: Error {
        let message: String
    }
}
