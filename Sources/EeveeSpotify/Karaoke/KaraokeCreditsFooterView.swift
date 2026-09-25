import SwiftUI

/// "Written by: ...", attribution and "Lyrics provided by ..." footer shown
/// beneath the last lyrics line. Attribution is a binding condition of the
/// Spicy Lyrics API terms: always the provider; for source == spicy_lyrics also
/// the maker and uploader, linked where a url is given. Those are absent for
/// other sources, so nothing empty is rendered.
struct KaraokeCreditsFooterView: View {
    let lyrics: KaraokeLyricsDto

    private var providerLabel: String? {
        SpicyLyricsRepository.providerName(for: lyrics.providerCode)
    }

    private func creditLine(_ prefix: String, name: String, url: String?) -> some View {
        HStack(spacing: 4) {
            Text(prefix)
                .foregroundColor(.white.opacity(0.4))

            if let url = url, let destination = URL(string: url) {
                Link(name, destination: destination)
                    .foregroundColor(.white.opacity(0.7))
            } else {
                Text(name)
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .font(.system(size: 12, weight: .regular))
    }

    var body: some View {
        let maker = (lyrics.makerName ?? "").isEmpty ? nil : lyrics.makerName
        let uploader = (lyrics.uploaderName ?? "").isEmpty ? nil : lyrics.uploaderName

        if !lyrics.songWriters.isEmpty || providerLabel != nil || maker != nil || uploader != nil {
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
                if let maker = maker {
                    creditLine("Made by", name: maker, url: lyrics.makerUrl)
                }
                if let uploader = uploader {
                    creditLine("Uploaded by", name: uploader, url: lyrics.uploaderUrl)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }
}
