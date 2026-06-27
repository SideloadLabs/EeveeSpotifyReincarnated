import SwiftUI

/// "Written by: ..." and "Lyrics provided by ..." footer shown beneath the
/// last lyrics line, matching the real extension's
/// Credits/ApplyLyricsCredits.ts and ApplyLyricsProvider.ts.
struct KaraokeCreditsFooterView: View {
    let lyrics: KaraokeLyricsDto

    private static let providerMap: [String: String] = [
        "spt": "Spotify",
        "aml": "Apple Music",
        "spl": "nontitled",
        "ldb": "Local DB",
    ]

    private var providerLabel: String? {
        guard let code = lyrics.providerCode else { return nil }
        if code == "ext" {
            return lyrics.providerDisplayName ?? "External Source"
        }
        return Self.providerMap[code]
    }

    var body: some View {
        if !lyrics.songWriters.isEmpty || providerLabel != nil {
            VStack(alignment: .center, spacing: 4) {
                if !lyrics.songWriters.isEmpty {
                    Text("Written by: \(lyrics.songWriters.joined(separator: ", "))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                if let providerLabel = providerLabel {
                    Text("Lyrics provided by \(providerLabel)")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }
}
